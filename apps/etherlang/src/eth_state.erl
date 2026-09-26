-module(eth_state).

%% State provider for local EVM execution.
%%
%% The node does not sync the state trie. Instead, account balance/nonce, code
%% and storage are fetched lazily from the upstream node on demand and memoised
%% in an ETS cache (short TTL for mutable tags such as `latest`, unbounded for
%% concrete block numbers). The EVM layers an immutable *overlay* on top: all
%% writes (SSTORE, value transfers, created code) live only in the overlay of
%% the running call and are discarded on revert, so upstream state is never
%% mutated.

-behaviour(gen_server).

-export([start_link/0]).
-export([new/2, overrides_from_json/1,
         account/2, balance/2, nonce/2, code/2, storage/3, exists/2,
         set_balance/3, set_nonce/3, set_code/3, set_storage/4,
         mark_created/2, is_created/2, set_destroyed/2, drop_if_empty/2, empty/2,
         commit/1, base_source/0, set_base_source/1,
         chain_id/0, address/1, address_hex/1, hex_to_bin/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TAB, eth_state_cache).
-define(TTL_MS, 3000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ensure_table(),
    {ok, #{}}.

%% ---------------------------------------------------------------------------
%% Call-state construction
%% ---------------------------------------------------------------------------

new(Block, Overrides) when is_map(Overrides) ->
    #{block => Block, overlay => normalize_overrides(Overrides)};
new(Block, _) ->
    #{block => Block, overlay => #{}}.

%% Callers spell a slot as an integer, a short binary or a full 32-byte word,
%% and the EVM reads it back as a full word. Canonicalising the keys once, at
%% construction, is what makes a write under one spelling visible to a read
%% under another -- without it, a seeded slot silently reads as zero.
normalize_overrides(Overrides) ->
    maps:fold(fun
                 ({store, A, Slot}, V, Acc) -> Acc#{ {store, address(A), slot_key(Slot)} => V};
                 (K, V, Acc) -> Acc#{K => V}
             end, #{}, Overrides).

overlay_put(#{overlay := O} = S, Key, Value) -> S#{overlay := O#{Key => Value}}.

%% ---------------------------------------------------------------------------
%% Reads (overlay first, then lazy upstream + cache)
%% ---------------------------------------------------------------------------

account(State, Addr) ->
    A = address(Addr),
    #{balance => balance(State, A), nonce => nonce(State, A)}.

balance(#{overlay := O} = S, Addr) ->
    case maps:get({balance, Addr}, O, undefined) of
        undefined -> base_balance(S, Addr);
        V -> V
    end.

nonce(#{overlay := O} = S, Addr) ->
    case maps:get({nonce, Addr}, O, undefined) of
        undefined -> base_nonce(S, Addr);
        V -> V
    end.

code(#{overlay := O} = S, Addr) ->
    case maps:get({destroyed, Addr}, O, false) of
        true -> <<>>;
        false ->
            case maps:get({code, Addr}, O, undefined) of
                undefined -> base_code(S, Addr);
                V -> V
            end
    end.

storage(#{overlay := O} = S, Addr, Slot) ->
    case maps:get({destroyed, Addr}, O, false) of
        true -> 0;
        false ->
            case maps:get({store, Addr, slot_key(Slot)}, O, undefined) of
                undefined -> base_storage(S, Addr, Slot);
                V -> V
            end
    end.

exists(State, Addr) ->
    A = address(Addr),
    not is_destroyed(State, A) andalso
        (balance(State, A) > 0 orelse nonce(State, A) > 0 orelse code(State, A) =/= <<>>).

%% ---------------------------------------------------------------------------
%% Writes (overlay only — never touches upstream)
%% ---------------------------------------------------------------------------

set_balance(State, Addr, V) -> overlay_put(State, {balance, address(Addr)}, eth_word:mask(V)).
set_nonce(State, Addr, V) -> overlay_put(State, {nonce, address(Addr)}, V).
set_code(State, Addr, Code) -> overlay_put(State, {code, address(Addr)}, Code).
set_storage(State, Addr, Slot, V) ->
    overlay_put(State, {store, address(Addr), slot_key(Slot)}, eth_word:mask(V)).

%% EIP-6780 bookkeeping (overlay-scoped, hence transaction-scoped: revert
%% paths restore pre-frame state which drops these markers automatically).
%% {created, A} records successful CREATEs; {destroyed, A} records full
%% self-destructs. Neither key can arrive via JSON overrides (only
%% balance/nonce/code/state/stateDiff are parsed), so clients cannot forge
%% them.
mark_created(State, Addr) -> overlay_put(State, {created, address(Addr)}, true).
is_created(#{overlay := O}, Addr) -> maps:get({created, Addr}, O, false).
set_destroyed(State, Addr) ->
    overlay_put(overlay_put(State, {destroyed, address(Addr)}, true),
                {code, address(Addr)}, <<>>).
is_destroyed(#{overlay := O}, Addr) -> maps:get({destroyed, Addr}, O, false).

%% EIP-161/158: an account that a transaction *touched* but left empty -- nonce 0,
%% balance 0, no code -- must not appear in the trie at all.
%%
%% This matters most for the case nobody thinks about: a zero-value transfer to
%% an address that does not exist yet. The transfer moves nothing, so if the
%% account is committed it is committed as an empty account, and the post-state
%% root then disagrees with every other client's by exactly that account. The
%% "touched" marking is what makes the rule expressible: without it there is no
%% way to tell "a transaction wrote zero here" from "a transaction created an
%% empty account here", and the first is legal while the second is not.
drop_if_empty(State, Addr) ->
    case empty(State, Addr) of
        true -> set_destroyed(State, Addr);
        false -> State
    end.

%% Is this account empty *as the state now stands*? Destroyed counts as empty:
%% a self-destructed account is exactly the empty-account case by definition.
empty(State, Addr) ->
    A = address(Addr),
    is_destroyed(State, A) orelse
        (balance(State, A) =:= 0 andalso
         nonce(State, A) =:= 0 andalso
         code(State, A) =:= <<>>).

%% ---------------------------------------------------------------------------
%% State overrides (eth_call 3rd parameter)
%% ---------------------------------------------------------------------------

%% { "0xaddr": { "balance":.., "nonce":.., "code":.., "state": {..}, "stateDiff": {..} } }
overrides_from_json(Map) when is_map(Map) ->
    maps:fold(fun(AddrHex, Spec, Acc) ->
                      A = address(AddrHex),
                      Acc1 = apply_override(A, Spec, Acc),
                      Acc1
              end, #{}, Map);
overrides_from_json(_) ->
    #{}.

apply_override(A, Spec, Acc0) when is_map(Spec) ->
    Acc1 = case maps:get(<<"balance">>, Spec, undefined) of
               undefined -> Acc0;
               B -> Acc0#{{balance, A} => eth_hex:decode(B)}
           end,
    Acc2 = case maps:get(<<"nonce">>, Spec, undefined) of
               undefined -> Acc1;
               N -> Acc1#{{nonce, A} => eth_hex:decode(N)}
           end,
    Acc3 = case maps:get(<<"code">>, Spec, undefined) of
               undefined -> Acc2;
               C -> Acc2#{{code, A} => hex_to_bin(C)}
           end,
    Acc4 = apply_slots(A, maps:get(<<"state">>, Spec, #{}), Acc3),
    apply_slots(A, maps:get(<<"stateDiff">>, Spec, #{}), Acc4);
apply_override(_A, _Spec, Acc) ->
    Acc.

apply_slots(A, Slots, Acc) when is_map(Slots) ->
    maps:fold(fun(K, V, Ac) ->
                      Ac#{{store, A, slot_key(eth_hex:decode(K))} => eth_hex:decode(V)}
              end, Acc, Slots);
apply_slots(_A, _Slots, Acc) ->
    Acc.

%% ---------------------------------------------------------------------------
%% Chain id (cached for the process lifetime)
%% ---------------------------------------------------------------------------

chain_id() ->
    case persistent_term:get({?MODULE, chain_id}, undefined) of
        undefined ->
            Id = case eth_rpc_client:call(<<"eth_chainId">>, []) of
                     {ok, Hex} -> eth_hex:decode(Hex);
                     _ -> 1
                 end,
            persistent_term:put({?MODULE, chain_id}, Id),
            Id;
        Id ->
            Id
    end.

%% ---------------------------------------------------------------------------
%% Base reads: local MPT or upstream RPC
%% ---------------------------------------------------------------------------

%% Two base sources, and the choice matters for honesty rather than taste.
%%
%% `upstream' fetches state from a peer and memoises it. That is fine for
%% eth_call and for a read-only view, but the node never mutates a peer's
%% state, so nothing it executes can produce a state root: there is no post-state
%% trie to hash.
%%
%% `mpt' reads the local MPT-backed store and lets commit/1 write back to it.
%% That is the mode a block has to be executed in for the resulting state root
%% to mean anything, and it requires the local store to already hold the
%% parent's state -- which the caller is responsible for checking, since
%% otherwise the root would be computed over a partial trie and look valid.
%%
%% The default stays `upstream' so existing read paths are unaffected.
base_source() ->
    case application:get_env(etherlang, eth_state_base_source) of
        {ok, mpt} -> mpt;
        _ -> upstream
    end.

set_base_source(Source) when Source =:= mpt; Source =:= upstream ->
    application:set_env(etherlang, eth_state_base_source, Source),
    ok.

block(#{block := B}) -> B.

%% Each base read dispatches on base_source/0 directly. Doing it per quantity
%% rather than through a shared helper keeps the two paths visible side by side
%% -- the point of the split is that they are genuinely different, and a reader
%% should be able to see both without jumping to another function.
base_balance(State, A) ->
    case base_source() of
        mpt -> mpt_default(mpt_balance(A), 0);
        upstream -> upstream_balance(block(State), A)
    end.

base_nonce(State, A) ->
    case base_source() of
        mpt -> mpt_default(mpt_nonce(A), 0);
        upstream -> upstream_nonce(block(State), A)
    end.

base_code(State, A) ->
    case base_source() of
        mpt -> mpt_default(mpt_code(A), <<>>);
        upstream -> upstream_code(block(State), A)
    end.

base_storage(State, A, Slot) ->
    case base_source() of
        mpt -> mpt_storage(A, Slot);
        upstream -> upstream_storage(block(State), A, Slot)
    end.

mpt_default(undefined, Default) -> Default;
mpt_default(V, _Default) -> V.

upstream_balance(Block, A) ->
    cached({balance, A, Block}, fun() ->
        rpc_int(<<"eth_getBalance">>, [address_hex(A), block_param(Block)])
    end).

upstream_nonce(Block, A) ->
    cached({nonce, A, Block}, fun() ->
        rpc_int(<<"eth_getTransactionCount">>, [address_hex(A), block_param(Block)])
    end).

upstream_code(Block, A) ->
    cached({code, A, Block}, fun() ->
        case eth_rpc_client:call(<<"eth_getCode">>, [address_hex(A), block_param(Block)]) of
            {ok, Hex} -> hex_to_bin(Hex);
            {error, _} -> <<>>
        end
    end).

upstream_storage(Block, A, Slot) ->
    cached({store, A, Slot, Block}, fun() ->
        rpc_int(<<"eth_getStorageAt">>,
                [address_hex(A), eth_hex:encode_int(Slot), block_param(Block)])
    end).

%% ---------------------------------------------------------------------------
%% Local MPT access
%% ---------------------------------------------------------------------------
%%
%% Every call goes through safe/1. The MPT is a named gen_server, and a caller
%% that is not the block-processing process can legitimately race its
%% supervisor during a restart. A read that degrades to the documented default
%% is recoverable; a read that kills the EVM is not.

mpt_account(A) ->
    safe(fun() -> eth_mpt:get_account(A) end).

mpt_balance(A) ->
    case mpt_account(A) of
        #{balance := B} when is_integer(B) -> B;
        _ -> undefined
    end.

mpt_nonce(A) ->
    case mpt_account(A) of
        #{nonce := N} when is_integer(N) -> N;
        _ -> undefined
    end.

mpt_code(A) ->
    case mpt_account(A) of
        #{codeHash := Hash} ->
            case safe(fun() -> eth_mpt:get_code(Hash) end) of
                C when is_binary(C) -> C;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

%% The MPT stores a slot value as minimal big-endian bytes, with zero stored as
%% the empty binary, so the read has to fold the bytes back into a word. An
%% absent slot reads as zero, which is also what a present-but-empty one means.
mpt_storage(A, Slot) ->
    case safe(fun() -> eth_mpt:get_storage(A, slot_key(Slot)) end) of
        undefined -> 0;
        <<>> -> 0;
        Bin when is_binary(Bin) -> binary:decode_unsigned(Bin)
    end.

safe(Fun) ->
    try Fun() catch _:_ -> undefined end.

%% ---------------------------------------------------------------------------
%% Commit
%% ---------------------------------------------------------------------------

%% Flush the overlay into the local MPT. Only meaningful in `mpt' base-source
%% mode: in `upstream' mode there is nothing to commit to, and committing would
%% mean writing state that was only ever a view of someone else's chain.
%%
%% Returns ok, or {error, Reason} when the local store is unavailable.
commit(#{overlay := O}) ->
    case base_source() of
        upstream ->
            {error, not_committable};
        mpt ->
            try
                lists:foreach(fun(A) -> commit_account(A, O) end, touched(O)),
                ok
            catch
                exit:{noproc, _} -> {error, state_unavailable};
                exit:{{nodedown, _}, _} -> {error, state_unavailable};
                Class:Reason -> {error, {commit_failed, Class, Reason}}
            end
    end.

%% Every address mentioned by an overlay write. Reads never create entries, so
%% this is exactly the set of accounts the block touched.
touched(O) ->
    lists:usort(lists:flatten([
        [A || {{balance, A}, _} <- maps:to_list(O)],
        [A || {{nonce, A}, _} <- maps:to_list(O)],
        [A || {{code, A}, _} <- maps:to_list(O)],
        [A || {{destroyed, A}, _} <- maps:to_list(O)],
        [A || {{created, A}, _} <- maps:to_list(O)],
        [A || {{store, A, _}, _} <- maps:to_list(O)]
    ])).

commit_account(A, O) ->
    case maps:get({destroyed, A}, O, false) of
        true ->
            %% A self-destructed account is removed entirely (EIP-6780/161).
            eth_mpt:delete_account(A);
        false ->
            {BaseBalance, BaseNonce} =
                case mpt_account(A) of
                    #{balance := B, nonce := N} -> {B, N};
                    _ -> {0, 0}
                end,
            Balance = overlay_or(maps:get({balance, A}, O, undefined), BaseBalance),
            Nonce = overlay_or(maps:get({nonce, A}, O, undefined), BaseNonce),
            Code = overlay_or(maps:get({code, A}, O, undefined), existing_code(A)),
            CodeHash = eth_keccak:hash(Code),
            ok = eth_mpt:put_code(CodeHash, Code),
            ok = eth_mpt:put_account(A, Balance, Nonce, CodeHash),
            commit_storage(A, O)
    end.

%% An overlay write wins; an absent one leaves the stored value alone. A field
%% the overlay never mentioned must keep the value the MPT already holds, or
%% committing a partially-written account would zero it.
overlay_or(undefined, Stored) -> Stored;
overlay_or(V, _Stored) -> V.

existing_code(A) ->
    case mpt_code(A) of
        C when is_binary(C) -> C;
        _ -> <<>>
    end.

%% Storage is written after the account so the per-account storage root is
%% recomputed from the slots that were actually set. A slot written back to
%% zero is deleted, because a zero slot must not appear in the trie at all.
commit_storage(A, O) ->
    Slots = [Slot || {{store, A2, Slot}, _} <- maps:to_list(O), A2 =:= A],
    lists:foreach(fun(Slot) ->
        Key = slot_key(Slot),
        case maps:get({store, A, Slot}, O) of
            0 -> eth_mpt:delete_storage(A, Key);
            V -> eth_mpt:put_storage(A, Key, V)
        end
    end, Slots).

%% The EVM carries slots as 32-byte words, but an override may supply a bare
%% integer or a short binary. All of them have to reach the store as the same
%% key, or a slot written through one spelling would be invisible through
%% another. Left-pad to a full word; truncate from the left if over-long.
slot_key(S) when is_binary(S) ->
    Pad = 32 - byte_size(S),
    case Pad >= 0 of
        true -> <<0:(Pad * 8), S/binary>>;
        false -> binary:part(S, byte_size(S) - 32, 32)
    end;
slot_key(S) when is_integer(S) -> <<S:256>>;
slot_key(_) -> <<0:256>>.

rpc_int(Method, Params) ->
    case eth_rpc_client:call(Method, Params) of
        {ok, Hex} -> eth_hex:decode(Hex);
        {error, _} -> 0
    end.

block_param(B) when is_integer(B) -> eth_hex:encode_int(B);
block_param(B) -> B.

%% TTL is only applied to mutable tags; concrete block numbers are immutable.
cached(Key, Fun) ->
    ensure_table(),
    try cached_lookup(Key, Fun)
    catch error:badarg ->
        %% Table vanished mid-request (owner died, supervisor restarting):
        %% serve uncached rather than killing the caller's HTTP request.
        Fun()
    end.

cached_lookup(Key, Fun) ->
    case ets:lookup(?TAB, Key) of
        [{_, V, Exp}] ->
            case Exp =:= infinity orelse Exp > erlang:monotonic_time(millisecond) of
                true -> V;
                false -> fetch_store(Key, Fun)
            end;
        [] ->
            fetch_store(Key, Fun)
    end.

fetch_store(Key, Fun) ->
    V = Fun(),
    Exp = ttl(Key),
    _ = try ets:insert(?TAB, {Key, V, Exp})
        catch error:badarg -> ok end,
    V.

ttl({_, _, Block}) -> tag_ttl(Block);
ttl({_, _, _, Block}) -> tag_ttl(Block).

tag_ttl(Block) when is_integer(Block) -> infinity;
tag_ttl(<<"latest">>) -> erlang:monotonic_time(millisecond) + ?TTL_MS;
tag_ttl(<<"pending">>) -> erlang:monotonic_time(millisecond) + ?TTL_MS;
tag_ttl(<<"safe">>) -> erlang:monotonic_time(millisecond) + ?TTL_MS;
tag_ttl(<<"finalized">>) -> erlang:monotonic_time(millisecond) + ?TTL_MS;
tag_ttl(_) -> erlang:monotonic_time(millisecond) + ?TTL_MS.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            _ = try ets:new(?TAB, [named_table, public, set, {read_concurrency, true}])
                catch error:badarg -> ok end,
            ok;
        _ ->
            ok
    end.

%% ---------------------------------------------------------------------------
%% Addresses / hex
%% ---------------------------------------------------------------------------

address(Addr) when is_binary(Addr), byte_size(Addr) =:= 20 -> Addr;
address(Addr) when is_binary(Addr) -> pad_address(hex_to_bin(Addr));
address(Addr) when is_integer(Addr) -> pad_address(eth_word:to_bytes(Addr, 20)).

pad_address(Bin) when byte_size(Bin) >= 20 ->
    binary:part(Bin, byte_size(Bin) - 20, 20);
pad_address(Bin) ->
    Pad = 20 - byte_size(Bin),
    <<0:(Pad * 8), Bin/binary>>.

address_hex(Addr) ->
    <<"0x", (lower_hex(Addr))/binary>>.

lower_hex(Bin) -> string:lowercase(binary:encode_hex(Bin)).

hex_to_bin(V) when is_binary(V) -> hex_to_bin(binary_to_list(V));
hex_to_bin(V) when is_integer(V) -> binary:encode_unsigned(V);
hex_to_bin([$0, $x | R]) -> hex_to_bin(R);
hex_to_bin([$0, $X | R]) -> hex_to_bin(R);
hex_to_bin([]) -> <<>>;
hex_to_bin(L) when is_list(L) -> list_to_binary(pairs(L)).

pairs([A, B | T]) -> [(hv(A) bsl 4) bor hv(B) | pairs(T)];
pairs([A]) -> [hv(A)];
pairs([]) -> [].

hv(C) when C >= $0, C =< $9 -> C - $0;
hv(C) when C >= $a, C =< $f -> C - $a + 10;
hv(C) when C >= $A, C =< $F -> C - $A + 10.

handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.
