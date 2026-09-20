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
         mark_created/2, is_created/2, set_destroyed/2,
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
    #{block => Block, overlay => Overrides};
new(Block, _) ->
    #{block => Block, overlay => #{}}.

overlay_put(#{overlay := O} = S, Key, Value) -> S#{overlay := O#{Key => Value}}.

%% ---------------------------------------------------------------------------
%% Reads (overlay first, then lazy upstream + cache)
%% ---------------------------------------------------------------------------

account(State, Addr) ->
    A = address(Addr),
    #{balance => balance(State, A), nonce => nonce(State, A)}.

balance(#{overlay := O} = S, Addr) ->
    case maps:get({balance, Addr}, O, undefined) of
        undefined -> base_balance(block(S), Addr);
        V -> V
    end.

nonce(#{overlay := O} = S, Addr) ->
    case maps:get({nonce, Addr}, O, undefined) of
        undefined -> base_nonce(block(S), Addr);
        V -> V
    end.

code(#{overlay := O} = S, Addr) ->
    case maps:get({destroyed, Addr}, O, false) of
        true -> <<>>;
        false ->
            case maps:get({code, Addr}, O, undefined) of
                undefined -> base_code(block(S), Addr);
                V -> V
            end
    end.

storage(#{overlay := O} = S, Addr, Slot) ->
    case maps:get({destroyed, Addr}, O, false) of
        true -> 0;
        false ->
            case maps:get({store, Addr, Slot}, O, undefined) of
                undefined -> base_storage(block(S), Addr, Slot);
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
    overlay_put(State, {store, address(Addr), Slot}, eth_word:mask(V)).

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
    maps:fold(fun(K, V, Ac) -> Ac#{{store, A, eth_hex:decode(K)} => eth_hex:decode(V)} end,
              Acc, Slots);
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
%% Base reads: cache + upstream
%% ---------------------------------------------------------------------------

block(#{block := B}) -> B.

base_balance(Block, A) ->
    cached({balance, A, Block}, fun() ->
        rpc_int(<<"eth_getBalance">>, [address_hex(A), block_param(Block)])
    end).

base_nonce(Block, A) ->
    cached({nonce, A, Block}, fun() ->
        rpc_int(<<"eth_getTransactionCount">>, [address_hex(A), block_param(Block)])
    end).

base_code(Block, A) ->
    cached({code, A, Block}, fun() ->
        case eth_rpc_client:call(<<"eth_getCode">>, [address_hex(A), block_param(Block)]) of
            {ok, Hex} -> hex_to_bin(Hex);
            {error, _} -> <<>>
        end
    end).

base_storage(Block, A, Slot) ->
    cached({store, A, Slot, Block}, fun() ->
        rpc_int(<<"eth_getStorageAt">>,
                [address_hex(A), eth_hex:encode_int(Slot), block_param(Block)])
    end).

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
