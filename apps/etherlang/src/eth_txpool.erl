-module(eth_txpool).
-behaviour(gen_server).

%% Pending transaction pool: signature + static validation, per-sender
%% nonce ordering (pending executable prefix vs queued future), price
%% eviction, and gossip ingress. No miner yet: `pending' exposes the
%% executable set for future block building.
%%
%% Dynamic checks (nonce, balance) run against a replaceable state term
%% (eth_state snapshot, refreshed via set_state/1). Tests inject fake
%% state; production refreshes it on new heads.

-export([start_link/1, add_raw/1, add_raw/2, add_map/2, add_map/3,
         has/1, has/2, get/2, pending/0, pending/1, queued/0, queued/1,
         status/0, status/1, set_state/1, set_state/2, drop/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_MAX, 1024).
-define(DEFAULT_PER_SENDER, 16).
-define(MAX_GAS, 30000000).

-record(st, {txs = #{},
             max = ?DEFAULT_MAX,
             per_sender = ?DEFAULT_PER_SENDER,
             state}).

start_link(Cfg) ->
    Name = maps:get(name, Cfg, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Cfg, []).

add_raw(Bin) -> add_raw(?MODULE, Bin).
add_raw(Name, Bin) -> gen_server:call(Name, {add_raw, Bin}).

add_map(Tx, State) -> add_map(?MODULE, Tx, State).
add_map(Name, Tx, State) -> gen_server:call(Name, {add_map, Tx, State}).

has(Hash) -> has(?MODULE, Hash).
has(Name, Hash) -> gen_server:call(Name, {has, Hash}).

get(Name, Hash) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> not_found;
        Pid -> get(Pid, Hash)
    end;
get(Pid, Hash) when is_pid(Pid) -> gen_server:call(Pid, {get, Hash}).

pending() -> pending(?MODULE).
pending(Name) -> gen_server:call(Name, pending).

queued() -> queued(?MODULE).
queued(Name) -> gen_server:call(Name, queued).

status() -> status(?MODULE).
status(Name) -> gen_server:call(Name, status).

set_state(State) -> set_state(?MODULE, State).
set_state(Name, State) -> gen_server:call(Name, {set_state, State}).

drop(Name, Hash) -> gen_server:call(Name, {drop, Hash}).

init(Cfg) ->
    {ok, #st{max = maps:get(max, Cfg, ?DEFAULT_MAX),
             per_sender = maps:get(per_sender, Cfg, ?DEFAULT_PER_SENDER),
             state = maps:get(state, Cfg, undefined)}}.

handle_call({add_raw, Bin}, _From, S) ->
    case eth_tx:from_rlp(Bin) of
        {ok, Tx} -> insert(S, Tx, Bin);
        {error, _} = E -> {reply, E, S}
    end;
handle_call({add_map, Tx, State}, _From, S) ->
    case eth_tx:to_rlp(Tx) of
        {ok, Bin} -> insert(S#st{state = State}, Tx#{<<"hash">> => tx_hash(Bin)}, Bin);
        {error, _} = E -> {reply, E, S}
    end;
handle_call({has, Hash}, _From, S) ->
    {reply, is_binary(Hash) andalso maps:is_key(norm(Hash), S#st.txs), S};
handle_call({get, Hash}, _From, S) ->
    case is_binary(Hash) andalso maps:find(norm(Hash), S#st.txs) of
        {ok, E} -> {reply, {ok, E}, S};
        _ -> {reply, not_found, S}
    end;
handle_call(pending, _From, S) ->
    {reply, pending_list(S), S};
handle_call(queued, _From, S) ->
    {reply, queued_list(S), S};
handle_call(status, _From, S) ->
    {reply, #{total => maps:size(S#st.txs),
              pending => length(pending_list(S)),
              queued => length(queued_list(S))}, S};
handle_call({set_state, State}, _From, S) ->
    {reply, ok, reclassify(S#st{state = State})};
handle_call({drop, Hash}, _From, S) ->
    case is_binary(Hash) of
        true -> {reply, ok, S#st{txs = maps:remove(norm(Hash), S#st.txs)}};
        false -> {reply, {error, bad_hash}, S}
    end;
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------

%% **At most one transaction per (sender, nonce), and a higher price replaces.**
%%
%% The pool was keyed on the transaction *hash* and nothing else, so two
%% transactions differing only in `gasPrice' were both admitted and both lived
%% here indefinitely. That is not a duplication the rest of the module could
%% absorb: only one of them can ever appear in a valid block, because a block
%% containing both applies the same account transition twice.
%%
%% The tie was then broken in `sender_pending/2', which sorts on `nonce' alone
%% with a `=<' comparator -- and `=<` returns true both ways for two equal
%% nonces, so the order that decided it was whatever `by_sender/1' happened to
%% produce. `by_sender/1' folds the map through a **prepending** accumulator, and
%% for a map this small that is a flatmap visited in key order, where the key is
%% the hash. So the winner was whichever of two keccak digests sorted first.
%%
%% Measured over 12 runs with a 1 gwei and a 2 gwei transaction at the same
%% (sender, nonce): the 2 gwei one won 8 and the 1 gwei one won 4, and the 2 gwei
%% one won in exactly the 8 runs where **its own hash was the larger**. Twelve of
%% twelve, no exceptions. The fee is therefore not a weak tiebreaker here, it is
%% not consulted at all -- and a user who bumps the price on a stuck transaction
%% has a coin flip on being ignored, while the loser still occupies a per-sender
%% and a global slot.
%%
%% **No price-bump threshold, deliberately.** No EIP specifies one and this node
%% has nothing to derive it from. Geth demands roughly 10%; adopting that number
%% would import a peer's mempool policy as though it were a rule. The cost of
%% omitting it is that anyone can churn a slot by bidding one wei more, which is
%% bounded by `per_sender'/`max' and costs only their own bandwidth -- and this
%% node authors no blocks, so there is nothing for them to gain.
%%
%% An equal price replaces rather than being refused, so re-submitting the same
%% transaction is idempotent on the newer copy instead of erroring.
insert(S, Tx, Bin) ->
    Hash = tx_hash(Bin),
    Key = norm(Hash),
    case maps:is_key(Key, S#st.txs) of
        true ->
            {reply, {ok, Hash}, S};
        false ->
            case validate(S, Tx) of
                {ok, Entry} ->
                    case same_nonce(S, Entry) of
                        [] ->
                            S1 = S#st{txs = (S#st.txs)#{Key => Entry}},
                            {reply, {ok, Hash}, enforce_caps(S1)};
                        Incumbents ->
                            Price = maps:get(price, Entry),
                            Beaten = [KV || KV = {_, Old} <- Incumbents,
                                           maps:get(price, Old) =< Price],
                            case length(Beaten) =:= length(Incumbents) of
                                false ->
                                    {reply, {error, replacement_underpriced}, S};
                                true ->
                                    Gone = [H || {H, _} <- Incumbents],
                                    Keep = [KV || KV = {H, _} <- maps:to_list(S#st.txs),
                                                not lists:member(H, Gone)],
                                    S1 = S#st{txs = maps:from_list([{Key, Entry} | Keep])},
                                    {reply, {ok, Hash}, enforce_caps(S1)}
                            end
                    end;
                {error, _} = E ->
                    {reply, E, S}
            end
    end.

%% The transactions this one would displace: same sender, same nonce, keyed as the
%% pool keys them. Returns `{Key, Entry}' pairs because an entry does not carry
%% its own key -- `by_sender/1' bolts `hash_key' on during the fold, and this
%% runs outside that fold.
same_nonce(S, Entry) ->
    Sender = maps:get(sender, Entry),
    Nonce = maps:get(nonce, Entry),
    [{H, E} || {H, E} <- maps:to_list(S#st.txs),
              maps:get(sender, E) =:= Sender,
              maps:get(nonce, E) =:= Nonce].

tx_hash(Bin) -> bin0x(eth_keccak:hash(Bin)).
norm(H) when is_binary(H) -> string:lowercase(H);
norm(_) -> error.

%% Admission runs the same validity rules block execution does.
%%
%% The pool used to run three checks of its own -- sender recovery, a chain id read
%% straight off the `chainId' field, and a gas sanity bound -- and nothing else.
%% Every other rule eth_tx:validate/2 enforces went unchecked at admission, so a
%% blob transaction carrying no versioned hashes, or no maxFeePerBlobGas, was
%% accepted here, handed a hash back to the caller and broadcast to its peers. It
%% was rejected later, when a block tried to execute it.
%%
%% Those rules were not missing, and they were not untested either. They were
%% tested through eth_block_builder:validate_transaction/2, which nothing in the
%% application calls -- the builder is neither started nor referenced outside one
%% test file. So the tests were green and the live path stayed open, which is the
%% failure mode where passing tests are the problem rather than the reassurance.
validate(S, Tx) ->
    case eth_tx:validate(Tx, pool_ctx()) of
        ok -> admit(S, Tx);
        {error, _} = E -> E
    end.

%% The pool's own share, and only that: what eth_tx:validate/2 is not asked to
%% decide because the answer belongs to the pool rather than to the transaction.
%%
%% Balance and nonce are read from the pool's state view and are what separate
%% `pending' from `queued'. eth_tx knows only whether the nonce matches, which
%% would collapse a gapped transaction into a rejection, so that distinction is
%% kept here. `base_nonce => unknown' records that the account could not be read
%% at all, so a later attempt can retry rather than mistake the gap for real.
admit(S, Tx) ->
    case eth_tx:sender(Tx) of
        {ok, Sender} ->
            State = S#st.state,
            Nonce = q(maps:get(<<"nonce">>, Tx, 0)),
            Price = price(Tx),
            Cost = cost(Tx, Price),
            case State of
                undefined ->
                    {ok, entry(Tx, Sender, Nonce, Price, Cost, unknown)};
                _ ->
                    SAddr = bin0x(Sender),
                    case (try eth_state:account(State, SAddr) catch _:_ -> error end) of
                        #{balance := B, nonce := N} when is_integer(N), is_integer(B) ->
                            case Nonce < N of
                                true -> {error, nonce_too_low};
                                false ->
                                    case B < Cost of
                                        true -> {error, insufficient_balance};
                                        false ->
                                            {ok, entry(Tx, Sender, Nonce, Price, Cost, N)}
                                    end
                            end;
                        _ ->
                            {error, no_state}
                    end
            end;
        {error, _} = E ->
            E
    end.

entry(Tx, Sender, Nonce, Price, Cost, Base) ->
    #{tx => Tx, sender => bin0x(Sender), nonce => Nonce,
      price => Price, cost => Cost, base_nonce => Base}.

%% The context admission is validated against. Deliberately short.
%%
%% chain_id and gas_limit are facts about this node, so they are supplied and their
%% rules are enforced here as well as at execution. The chain id is the same
%% eth_fork_schedule:chain_id/0 the block path reads, and the pool's own version
%% used to hardcode 11155111 -- Sepolia's. That read as a chain id *assumption*
%% dressed as a rule: on any other network it rejects every transaction and the
%% pool is a black hole, and it disagreed with eth_block about which chain this
%% node is on, so a node could accept into its pool what it then refused to
%% finalize. Delegating also makes the pool's rule stronger where it was weaker:
%% eth_tx derives a legacy transaction's chain id from `v', so a transaction whose
%% `chainId' field contradicts its own signature is now caught, and a legitimate
%% EIP-155 transaction that carries only `v' is no longer rejected for lacking
%% the field. gas_limit likewise replaces a hardcoded ceiling with the one the
%% block path enforces, so the two cannot drift apart.
%%
%% base_fee and blob_base_fee are *not* supplied. Both depend on the block being
%% built -- the first on the parent's gas use, the second on the parent's excess
%% blob gas -- so neither is knowable when a transaction is submitted, and
%% supplying a guess would reject transactions a later block would have accepted.
%% eth_tx treats an absent key as the rule being unchecked rather than passed, so
%% omitting them defers both floors to block execution, where the real values
%% exist. For the same reason no balance_of/nonce_of fun is passed: those checks
%% belong to admit/2 above.
pool_ctx() ->
    #{chain_id => eth_fork_schedule:chain_id(),
      gas_limit => ?MAX_GAS}.

price(Tx) ->
    case maps:get(<<"maxFeePerGas">>, Tx, undefined) of
        undefined -> to_int(maps:get(<<"gasPrice">>, Tx, 0));
        Fee -> to_int(Fee)
    end.

cost(Tx, Price) ->
    Price * to_int(maps:get(<<"gas">>, Tx, 0)) + to_int(maps:get(<<"value">>, Tx, 0)).

%% Executable prefix per sender: contiguous nonces from the base nonce
%% (state nonce, or the sender's own minimum when state is unknown).
pending_list(S) ->
    lists:append([sender_pending(Txs, base_of(Txs, S)) ||
                     {_Sender, Txs} <- maps:to_list(by_sender(S))]).

queued_list(S) ->
    Pend = sets:from_list([maps:get(hash_key, E) || E <- pending_list(S)]),
    [E || {Hash, E} <- maps:to_list(S#st.txs),
          not sets:is_element(Hash, Pend)].

by_sender(S) ->
    maps:fold(fun(Hash, E, Acc) ->
        Sender = maps:get(sender, E),
        E1 = E#{hash_key => Hash},
        maps:update_with(Sender, fun(L) -> [E1 | L] end, [E1], Acc)
    end, #{}, S#st.txs).

base_of([], _S) -> 0;
base_of(Txs, _S) ->
    case [N || E <- Txs, N <- [maps:get(base_nonce, E, unknown)], N =/= unknown] of
        [] ->
            lists:min([maps:get(nonce, E) || E <- Txs]);
        Known ->
            lists:min(Known)
    end.

%% Reclassify after state refresh: drop transactions stale against the
%% new state nonces (executable sets recompute on read).
reclassify(#st{state = undefined} = S) -> S;
reclassify(S) ->
    Txs = maps:filter(fun(_, E) -> not stale(S#st.state, E) end, S#st.txs),
    S#st{txs = Txs}.

stale(State, E) ->
    SAddr = maps:get(sender, E),
    Current = (try maps:get(nonce, eth_state:account(State, SAddr))
               catch _:_ -> undefined end),
    is_integer(Current) andalso maps:get(nonce, E) < Current.

%% **The `=<' comparator below is now safe because it can no longer see a tie.**
%% Two entries at the same sender and nonce used to coexist, and `=<` returns true
%% in both directions for equal nonces, so the resulting order was whatever
%% `by_sender/1''s prepending accumulator produced -- which is decided by the two
%% transaction hashes. `insert/3' now holds at most one per (sender, nonce), so
%% this sort sees distinct nonces and is a total order. Do not relax that.
sender_pending(Txs, Base) ->
    Sorted = lists:sort(fun(A, B) -> maps:get(nonce, A) =< maps:get(nonce, B) end, Txs),
    take_contiguous(Sorted, Base).

take_contiguous([], _) -> [];
take_contiguous([E | Rest], N) ->
    case maps:get(nonce, E) of
        N -> [E | take_contiguous(Rest, N + 1)];
        _ -> []
    end.

%% Caps: per-sender count (drop highest nonce), then global (drop lowest
%% price, ties to highest nonce).
enforce_caps(S) ->
    S1 = maps:fold(fun(Sender, _, Acc) -> cap_sender(Acc, Sender) end,
                   S, by_sender(S)),
    cap_global(S1).

cap_sender(S, Sender) ->
    Mine = [{H, E} || {H, E} <- maps:to_list(S#st.txs),
                      maps:get(sender, E) =:= Sender],
    case length(Mine) > S#st.per_sender of
        false -> S;
        true ->
            {Worst, _} = lists:last(lists:sort(
                                      fun({_, A}, {_, B}) ->
                                          maps:get(nonce, A) =< maps:get(nonce, B)
                                      end, Mine)),
            S#st{txs = maps:remove(Worst, S#st.txs)}
    end.

cap_global(S) when map_size(S#st.txs) =< S#st.max -> S;
cap_global(S) ->
    {Worst, _} = hd(lists:sort(
                      fun({_, A}, {_, B}) ->
                          {maps:get(price, A), 0 - maps:get(nonce, A)} =<
                          {maps:get(price, B), 0 - maps:get(nonce, B)}
                      end, maps:to_list(S#st.txs))),
    cap_global(S#st{txs = maps:remove(Worst, S#st.txs)}).

q(I) when is_integer(I) -> I;
q(B) when is_binary(B) ->
    try eth_hex:decode(B) catch _:_ -> 0 end;
q(_) -> 0.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) ->
    try eth_hex:decode(B) catch _:_ -> 0 end;
to_int(_) -> 0.

bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.
