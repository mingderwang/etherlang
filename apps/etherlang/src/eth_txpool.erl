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
-define(INTRINSIC_BASE, 21000).
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

insert(S, Tx, Bin) ->
    Hash = tx_hash(Bin),
    Key = norm(Hash),
    case maps:is_key(Key, S#st.txs) of
        true ->
            {reply, {ok, Hash}, S};
        false ->
            case validate(S, Tx) of
                {ok, Entry} ->
                    S1 = enforce_caps(S#st{txs = (S#st.txs)#{Key => Entry}}),
                    {reply, {ok, Hash}, S1};
                {error, _} = E ->
                    {reply, E, S}
            end
    end.

tx_hash(Bin) -> bin0x(eth_keccak:hash(Bin)).
norm(H) when is_binary(H) -> string:lowercase(H);
norm(_) -> error.

%% Static + dynamic validation. Entry carries price for ordering.
validate(S, Tx) ->
    case {eth_tx:sender(Tx), tx_chain_ok(Tx), tx_gas_ok(Tx)} of
        {{ok, Sender}, true, true} ->
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
        {{error, _} = E, _, _} ->
            E;
        _ ->
            {error, invalid_tx}
    end.

entry(Tx, Sender, Nonce, Price, Cost, Base) ->
    #{tx => Tx, sender => bin0x(Sender), nonce => Nonce,
      price => Price, cost => Cost, base_nonce => Base}.

%% Chain ID must be Sepolia; unprotected legacy (no chain) is rejected.
tx_chain_ok(Tx) ->
    case maps:get(<<"chainId">>, Tx, undefined) of
        undefined ->
            %% Legacy without EIP-155: only accepted with explicit v (still
            %% replayable — reject).
            false;
        C ->
            to_int(C) =:= 11155111
    end.

%% Gas sanity: known bounds, intrinsic floor, non-zero limit.
tx_gas_ok(Tx) ->
    Gas = to_int(maps:get(<<"gas">>, Tx, 0)),
    Gas > 0 andalso Gas =< ?MAX_GAS andalso Gas >= intrinsic(Tx).

intrinsic(Tx) ->
    Data = tx_data(Tx),
    AL = maps:get(<<"accessList">>, Tx, []),
    ?INTRINSIC_BASE + data_cost(Data) + al_cost(AL).

tx_data(Tx) ->
    Raw = maps:get(<<"input">>, Tx, maps:get(<<"data">>, Tx, <<>>)),
    case Raw of
        <<"0x", Rest/binary>> ->
            try binary:decode_hex(Rest) catch _:_ -> <<>> end;
        B when is_binary(B) ->
            try binary:decode_hex(B) catch _:_ -> <<>> end;
        _ ->
            <<>>
    end.

data_cost(Data) when is_binary(Data) ->
    lists:foldl(fun(B, Acc) ->
        case B of
            0 -> Acc + 4;
            _ -> Acc + 16
        end
    end, 0, binary_to_list(Data));
data_cost(_) ->
    0.

al_cost(AL) when is_list(AL) ->
    lists:foldl(fun(E, Acc) ->
        Keys = maps:get(<<"storageKeys">>, E, []),
        Acc + 2400 + 1900 * length(Keys)
    end, 0, AL);
al_cost(_) ->
    0.

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
