-module(eth_statesync).
-behaviour(gen_server).

%% Snap state heal: pages account/storage ranges from snap peers with
%% boundary-proof verification into eth_statestore, then bytecodes.
%% One stateRoot at a time; progress is in-memory (a restart re-heals).
%% Opt-in via STATE_SYNC_ENABLED. RPC reads served from the store fall
%% back to proxy until the needed data has landed.

-export([start_link/1, status/0, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(INTERVAL_MS, 5000).
-define(CHUNK_BYTES, 500000).
-define(EMPTY_ROOT, <<16#56, 16#e8, 16#1f, 16#17, 16#1b, 16#cc, 16#55, 16#a6,
                      16#ff, 16#83, 16#45, 16#e6, 16#92, 16#c0, 16#f8, 16#6e,
                      16#5b, 16#48, 16#e0, 16#1b, 16#99, 16#6c, 16#ad, 16#c0,
                      16#01, 16#62, 16#2f, 16#b5, 16#e3, 16#63, 16#b4, 16#21>>).
-define(EMPTY_CODE, <<16#c5, 16#d2, 16#46, 16#01, 16#86, 16#f7, 16#23, 16#3c,
                      16#92, 16#7e, 16#7d, 16#b8, 16#c0, 16#09, 16#79, 16#5c,
                      16#97, 16#16, 16#82, 16#2f, 16#27, 16#bf, 16#07, 16#f7,
                      16#ef, 16#c9, 16#84, 16#ac, 16#de, 16#0a, 16#ac, 16#ad>>).
-define(MAX_HASH, <<16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                    16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                    16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                    16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff>>).

-record(st, {chain = eth_chain,
             store = eth_statestore,
             peer_mgr = eth_peer,
             peer,
             interval = ?INTERVAL_MS,
             root,
             origin,
             phase = accounts,
             pending = [],
             codes = [],
             done = 0}).

start_link(Cfg) ->
    Name = maps:get(name, Cfg, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Cfg, []).

status() -> status(?MODULE).
status(Name) -> gen_server:call(Name, status).

init(Cfg) ->
    Interval = maps:get(interval, Cfg, ?INTERVAL_MS),
    erlang:send_after(Interval, self(), tick),
    {ok, #st{chain = maps:get(chain, Cfg, eth_chain),
             store = maps:get(store, Cfg, eth_statestore),
             peer_mgr = maps:get(peer_mgr, Cfg, eth_peer),
             peer = maps:get(peer, Cfg, undefined),
             interval = Interval,
             origin = <<0:256>>}}.

handle_call(status, _From, S) ->
    {reply, #{root => S#st.root, phase => S#st.phase,
              origin => S#st.origin, done => S#st.done,
              queued => length(S#st.pending) + length(S#st.codes)}, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(tick, S) ->
    erlang:send_after(S#st.interval, self(), tick),
    {noreply, heal_tick(S)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------

heal_tick(S) ->
    case head_root(S#st.chain) of
        {error, _} ->
            S;
        {ok, Root} ->
            S1 = case S#st.root of
                     Root -> S;
                     _ ->
                         logger:notice("etherlang: state heal targeting ~s",
                                       [binary:encode_hex(binary:part(Root, 0, 4))]),
                         S#st{root = Root, origin = <<0:256>>,
                              phase = accounts, pending = [], codes = [],
                              done = 0}
                 end,
            case snap_peer(S1) of
                {ok, Pid} -> heal_step(S1, Pid);
                error -> S1
            end
    end.

head_root(Chain) ->
    try
        {N, _} = eth_chain:head(Chain),
        {ok, Block, _} = eth_chain:get_by_number(Chain, N),
        {ok, hex_to_bin(maps:get(<<"stateRoot">>, Block))}
    catch _:_ ->
        {error, no_head}
    end.

snap_peer(#st{peer = Pid}) when is_pid(Pid) -> {ok, Pid};
snap_peer(S) ->
    Infos = (try eth_peer:peers(S#st.peer_mgr) catch _:_ -> [] end),
    case [Pid || {Pid, Info} <- Infos, is_map(Info),
                 #{eth := #{snap := true}} <- [Info]] of
        [Pid | _] -> {ok, Pid};
        [] -> error
    end.

heal_step(#st{phase = accounts} = S, Pid) ->
    fetch_accounts(S, Pid);
heal_step(#st{phase = storage} = S, Pid) ->
    fetch_storage(S, Pid);
heal_step(#st{phase = codes} = S, Pid) ->
    fetch_codes(S, Pid);
heal_step(#st{phase = done} = S, _Pid) ->
    S.

fetch_accounts(S, Pid) ->
    Req = {snap_account_range, S#st.root, S#st.origin, ?MAX_HASH},
    case gen_server:call(Pid, Req, 30000) of
        {ok, [Hashes, Accounts, Proof]} ->
            case eth_snap:verify_account_range(Hashes, Accounts, Proof,
                                               S#st.root) of
                {ok, Pairs, _Complete} ->
                    ok = eth_statestore:put_accounts(S#st.store, Pairs),
                    S1 = queue_storage(S, Pairs),
                    S2 = queue_codes(S1, Pairs),
                    case Pairs of
                        [] ->
                            logger:notice("etherlang: state heal accounts done (~p stored)",
                                          [S2#st.done]),
                            S2#st{phase = storage};
                        _ ->
                            {LastH, _} = lists:last(Pairs),
                            case LastH of
                                ?MAX_HASH ->
                                    logger:notice("etherlang: state heal accounts done (~p stored)",
                                                  [S2#st.done]),
                                    S2#st{phase = storage};
                                _ ->
                                    S2#st{origin = inc_hash(LastH),
                                          done = S2#st.done + length(Pairs)}
                            end
                    end;
                {error, Reason} ->
                    logger:warning("etherlang: snap accounts rejected (~p)", [Reason]),
                    S
            end;
        {error, Reason} ->
            logger:debug("etherlang: snap accounts unavailable (~p)", [Reason]),
            S
    end.

%% Queue storage work for accounts with non-empty storage roots.
queue_storage(S, Pairs) ->
    More = [{AcctH, StorageRoot, <<0:256>>} ||
               {AcctH, AcctRLP} <- Pairs,
               {ok, [_, _, StorageRoot, _]} <- [decode_acct(AcctRLP)],
               StorageRoot =/= ?EMPTY_ROOT],
    S#st{pending = (S#st.pending) ++ More}.

%% Queue bytecode fetches for non-empty code hashes.
queue_codes(S, Pairs) ->
    More = [CodeHash ||
               {_, AcctRLP} <- Pairs,
               {ok, [_, _, _, CodeHash]} <- [decode_acct(AcctRLP)],
               CodeHash =/= ?EMPTY_CODE],
    S#st{codes = S#st.codes ++ More}.

decode_acct(RLP) ->
    case eth_rlp:decode(RLP) of
        {ok, [_, _, _, _] = L, <<>>} -> {ok, L};
        _ -> error
    end.

fetch_storage(#st{pending = [{AcctH, SRoot, Origin} | Rest]} = S, Pid) ->
    Req = {snap_storage_range, S#st.root, AcctH, Origin, ?MAX_HASH},
    case gen_server:call(Pid, Req, 30000) of
        {ok, [Hashes, Slots, Proof]} ->
            case eth_snap:verify_storage_range(Hashes, Slots, Proof, SRoot) of
                {ok, Pairs, _} ->
                    ok = eth_statestore:put_storage(S#st.store, AcctH, Pairs),
                    S1 = S#st{pending = Rest,
                              done = S#st.done + length(Pairs)},
                    case Pairs of
                        [] ->
                            fetch_storage(S1, Pid);
                        _ ->
                            %% Partial page: continue from successor next tick.
                            {LastH, _} = lists:last(Pairs),
                            case LastH of
                                ?MAX_HASH -> S1;
                                _ -> S1#st{pending = [{AcctH, SRoot, inc_hash(LastH)} | Rest]}
                            end
                    end;
                {error, Reason} ->
                    logger:warning("etherlang: snap storage rejected (~p)", [Reason]),
                    S
            end;
        {error, Reason} ->
            logger:debug("etherlang: snap storage unavailable (~p)", [Reason]),
            S
    end;
fetch_storage(S, _Pid) ->
    %% Storage queue drained: move to codes (or done).
    case S#st.codes of
        [] ->
            logger:notice("etherlang: state heal complete (~p items)", [S#st.done]),
            S#st{phase = done};
        _ ->
            S#st{phase = codes}
    end.

fetch_codes(#st{codes = []} = S, _Pid) ->
    logger:notice("etherlang: state heal complete (~p items)", [S#st.done]),
    S#st{phase = done};
fetch_codes(S, Pid) ->
    Batch = lists:sublist(S#st.codes, 32),
    case gen_server:call(Pid, {snap_bytecodes, Batch}, 30000) of
        {ok, Codes} ->
            lists:foreach(fun(Code) ->
                ok = eth_statestore:put_code(S#st.store,
                                             eth_keccak:hash(Code), Code)
            end, [C || C <- Codes, is_binary(C), C =/= <<>>]),
            Rest = lists:nthtail(min(length(Batch), length(S#st.codes)), S#st.codes),
            S1 = S#st{codes = Rest, done = S#st.done + length(Batch)},
            case Rest of
                [] ->
                    logger:notice("etherlang: state heal complete (~p items)",
                                  [S1#st.done]),
                    S1#st{phase = done};
                _ ->
                    S1
            end;
        {error, Reason} ->
            logger:debug("etherlang: snap bytecodes unavailable (~p)", [Reason]),
            S
    end.

inc_hash(Bin) when byte_size(Bin) =:= 32 ->
    I = binary:decode_unsigned(Bin),
    <<((I + 1) band ((1 bsl 256) - 1)):256>>.

hex_to_bin(<<"0x", R/binary>>) -> binary:decode_hex(R);
hex_to_bin(B) when is_binary(B) -> binary:decode_hex(B).
