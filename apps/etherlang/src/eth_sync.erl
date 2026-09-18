-module(eth_sync).
-behaviour(gen_server).

%% Chain synchroniser.
%%
%% Strategy (the "no pain" part): we sync through a standard Ethereum
%% JSON-RPC endpoint rather than implementing devp2p/RLPx from scratch. The
%% upstream node is treated as the source of truth for canonicality (there is
%% no EVM yet, so execution is not replayed); we still validate the structural
%% integrity of the chain:
%%
%%   * contiguous block numbers (head + 1 per append),
%%   * parentHash linkage against the locally stored canonical hash,
%%   * upwards/downwards reorgs are detected and the local chain rewound to
%%     the common ancestor, which is found by a bounded ancestor walk.
%%
%% Two-phase sync:
%%   * gap mode: walk start-block .. upstream head in windows, storing the
%%     most recent `body_window' blocks with full bodies and everything older
%%     with header-only (transactions as hashes) to keep sync fast and light.
%%   * follow mode: poll eth_blockNumber and fetch new blocks as they appear
%%     (works across a restart thanks to persisted head).

-export([start_link/1, start_link/2, status/0, status/1, head/0, head/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {chain = eth_chain,
             concurrency = 8,
             body_window = 100000,
             poll_ms = 5000,
             retry_ms = 2000,
             max_reorg = 256,
             budget_max = 2048,
             budget = 2048,
             start_block = latest,
             mode = starting,
             synced = false,
             start = 0,
             target = 0,
             appended = 0,
             failed = 0,
             reorgs = 0,
             last_log = 0}).

start_link(Cfg) -> start_link(eth_sync, maps:merge(defaults(), Cfg)).
start_link(Name, Cfg) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, maps:merge(defaults(), Cfg)}, []).

status() -> status(eth_sync).
status(Name) -> gen_server:call(Name, status).

head() -> head(eth_sync).
head(Name) -> gen_server:call(Name, head).

defaults() ->
    #{chain => eth_chain,
      concurrency => 8,
      body_window => 100000,
      poll_interval_ms => 5000,
      sync_retry_ms => 2000,
      max_reorg_depth => 256,
      sync_budget => 2048,
      start_block => latest}.

init({Name, Cfg}) ->
    S = #st{chain = maps:get(chain, Cfg),
            concurrency = maps:get(concurrency, Cfg),
            body_window = maps:get(body_window, Cfg),
            poll_ms = maps:get(poll_interval_ms, Cfg),
            retry_ms = maps:get(sync_retry_ms, Cfg),
            max_reorg = maps:get(max_reorg_depth, Cfg),
            budget = maps:get(sync_budget, Cfg),
            start_block = maps:get(start_block, Cfg)},
    _ = Name,
    logger:notice("etherlang sync starting"),
    self() ! tick,
    {ok, S#st{budget = maps:get(sync_budget, Cfg), budget_max = maps:get(sync_budget, Cfg)}}.

handle_call(status, _From, S) ->
    HeadN = local_head_num(S#st.chain),
    {reply, syncing_object(S, HeadN), S};

handle_call(head, _From, S) ->
    {reply, eth_chain:head(S#st.chain), S};

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(tick, S) ->
    S1 = try run_once(S)
        catch C:E:St ->
            logger:error("etherlang: sync tick crashed (~p:~p) ~p", [C, E, St]),
            S
        end,
    erlang:send_after(S1#st.poll_ms, self(), tick),
    {noreply, S1};

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Main loop
%% ---------------------------------------------------------------------------

run_once(S) ->
    case upstream_block_number() of
        {ok, HeadU} ->
            S0 = (S#st{mode = sync, budget = S#st.budget_max})#st{target = HeadU},
            track_finalized(S0#st.chain),
            case local_head(S0#st.chain) of
                undefined ->
                    From = anchor(S0, HeadU),
                    sync_range(S0, From, HeadU);
                {HeadN, _} when HeadN > HeadU ->
                    rewind_to_upstream(S0, HeadU);
                {HeadN, _} ->
                    sync_range(S0, HeadN + 1, HeadU)
            end;
        {error, Reason} ->
            logger:warning("etherlang: upstream unreachable (~p); will retry", [Reason]),
            S#st{mode = upstream_down, failed = S#st.failed + 1}
    end.

%% Pull the upstream finalized checkpoint and record it (never moves back).
track_finalized(Chain) ->
    case try eth_rpc_client:call(<<"eth_getBlockByNumber">>, [<<"finalized">>, false])
         catch _:_ -> error end of
        {ok, Block} when is_map(Block) ->
            case eth_header:number(Block) of
                undefined -> ok;
                N -> eth_chain:set_finalized(Chain, N)
            end;
        _ ->
            ok
    end.

%% Where to start when the local store is empty.
anchor(S, HeadU) ->
    case S#st.start_block of
        latest -> max(HeadU, 0);
        N when is_integer(N), N >= 0 -> min(N, HeadU)
    end.

%% Local head is above upstream head: either upstream reorged downwards or we
%% fetched a stale fork tip. Reconcile by checking the current canonical hash.
rewind_to_upstream(S, HeadU) ->
    case fetch_block(HeadU, false) of
        {ok, Block} ->
            Hash = maps:get(<<"hash">>, Block),
            case eth_chain:canonical_hash(S#st.chain, HeadU) of
                Hash ->
                    case eth_chain:rewind(S#st.chain, HeadU) of
                        ok -> S#st{mode = follow};
                        {error, Reason} -> rewind_refused(S, Reason)
                    end;
                _Other ->
                    case ancestor_walk(S, Hash) of
                        {ok, CA} ->
                            case eth_chain:rewind(S#st.chain, CA) of
                                ok -> S#st{mode = follow, reorgs = S#st.reorgs + 1};
                                {error, Reason} -> rewind_refused(S, Reason)
                            end;
                        error ->
                            S
                    end
            end;
        {error, _} ->
            S
    end.

rewind_refused(S, {below_finality, F}) ->
    logger:error("etherlang: upstream reorg below finalized ~p; refusing", [F]),
    S#st{failed = S#st.failed + 1};
rewind_refused(S, Reason) ->
    logger:error("etherlang: rewind refused (~p)", [Reason]),
    S#st{failed = S#st.failed + 1}.

sync_range(S, _From, _To) when _From > _To ->
    S#st{mode = follow, synced = true};
sync_range(S, _From, _To) when S#st.budget =< 0 ->
    S#st{mode = gap, synced = false};
sync_range(S, From, To) ->
    N = min(S#st.concurrency, To - From + 1),
    Req = [{From + I - 1, is_full_from(S, From + I - 1, To)} || I <- lists:seq(1, N)],
    case fetch_window(S, Req) of
        {ok, Blocks} ->
            case eth_chain:append(S#st.chain, Blocks) of
                ok ->
                    A = S#st.appended + N,
                    S1 = (S#st{appended = A, budget = S#st.budget - N})#st{
                            last_log = maybe_log(S, A)},
                    sync_range(S1, From + N, To);
                {reorg, CA} ->
                    logger:notice("etherlang: reorg to ~p", [CA]),
                    sync_range(S#st{reorgs = S#st.reorgs + 1}, CA + 1, To);
                {missing_parent, Parent} ->
                    case ancestor_walk(S, Parent) of
                        {ok, CA} ->
                            case eth_chain:rewind(S#st.chain, CA) of
                                ok ->
                                    logger:notice("etherlang: deep reorg, rewound to ~p", [CA]),
                                    sync_range(S#st{reorgs = S#st.reorgs + 1}, CA + 1, To);
                                {error, Reason} ->
                                    rewind_refused(S, Reason)
                            end;
                        error ->
                            S#st{failed = S#st.failed + 1}
                    end;
                {error, {bad_block, N, Reason}} ->
                    logger:error("etherlang: rejecting block ~p: ~p", [N, Reason]),
                    S#st{failed = S#st.failed + 1};
                {error, {below_finality, F}} ->
                    logger:error("etherlang: refusing rewind below finalized ~p", [F]),
                    S#st{failed = S#st.failed + 1};
                {error, Reason} ->
                    logger:error("etherlang: append failed (~p)", [Reason]),
                    S#st{failed = S#st.failed + 1}
            end;
        {error, Reason} ->
            logger:warning("etherlang: window fetch failed (~p); will retry", [Reason]),
            S#st{failed = S#st.failed + 1}
    end.

is_full_from(S, Num, HeadU) ->
    Num >= (HeadU - S#st.body_window) andalso Num >= 0.

maybe_log(S, Appended) ->
    Step = 1024,
    case Appended - S#st.last_log >= Step orelse S#st.mode =:= starting of
        true ->
            HeadN = local_head_num(S#st.chain),
            logger:info("etherlang: synced ~p blocks, head=~p target=~p mode=~p",
                        [Appended, HeadN, S#st.target, S#st.mode]),
            Appended;
        false ->
            S#st.last_log
    end.

%% ---------------------------------------------------------------------------
%% Fetching (bounded parallel window)
%% ---------------------------------------------------------------------------

upstream_block_number() ->
    case eth_rpc_client:call(<<"eth_blockNumber">>, []) of
        {ok, Hex} when is_binary(Hex) -> {ok, eth_hex:decode(Hex)};
        {ok, _} -> {error, bad_block_number};
        {error, _} = E -> E
    end.

fetch_block(Num, Full) ->
    case eth_rpc_client:call(<<"eth_getBlockByNumber">>, [eth_hex:encode_int(Num), Full]) of
        {ok, Block} when is_map(Block) -> {ok, Block};
        {ok, _} -> {error, not_a_block};
        {error, _} = E -> E
    end.

fetch_window(S, Req) ->
    Ref = make_ref(),
    Self = self(),
    Deadline = erlang:monotonic_time(millisecond) + 120000,
    [spawn_monitor(fun() ->
        R = fetch_block(Num, Full),
        Self ! {Ref, Num, Full, R}
    end) || {Num, Full} <- Req],
    collect_window(Ref, length(Req), 0, [], Deadline, S).

collect_window(_Ref, Total, Got, Acc, _Deadline, _S) when Got >= Total ->
    {ok, lists:sort(fun({A, _, _}, {B, _, _}) -> A =< B end, Acc)};
collect_window(Ref, Total, Got, Acc, Deadline, S) ->
    Now = erlang:monotonic_time(millisecond),
    receive
        {Ref, N, Full, {ok, Block}} ->
            collect_window(Ref, Total, Got + 1, [{N, Block, Full} | Acc], Deadline, S);
        {Ref, _N, _Full, {error, Reason}} ->
            {error, Reason};
        {'DOWN', _, process, _, _} ->
            collect_window(Ref, Total, Got, Acc, Deadline, S)
    after max(1, Deadline - Now) ->
        {error, window_timeout}
    end.

%% ---------------------------------------------------------------------------
%% Reorg ancestor walk
%% ---------------------------------------------------------------------------

ancestor_walk(S, StartHash) ->
    do_walk(S, StartHash, 0).

do_walk(_S, _H, Depth) when Depth > _S#st.max_reorg ->
    logger:error("etherlang: reorg deeper than ~p; giving up on this branch", [_S#st.max_reorg]),
    error;
do_walk(S, H, Depth) ->
    case eth_rpc_client:call(<<"eth_getBlockByHash">>, [H, false]) of
        {ok, Block} when is_map(Block) ->
            BHash = maps:get(<<"hash">>, Block),
            Num = eth_hex:decode(maps:get(<<"number">>, Block)),
            case below_finality(S#st.chain, Num) of
                true ->
                    logger:error("etherlang: reorg reaches below finalized checkpoint", []),
                    error;
                false ->
                    case eth_chain:canonical_hash(S#st.chain, Num) of
                        BHash -> {ok, Num};
                        _ -> do_walk(S, maps:get(<<"parentHash">>, Block), Depth + 1)
                    end
            end;
        {ok, _} ->
            {error, not_a_block};
        {error, _} = E ->
            E
    end.

below_finality(Chain, Num) ->
    case try eth_chain:finalized(Chain) catch _:_ -> error end of
        F when is_integer(F) -> Num < F;
        _ -> false
    end.

%% ---------------------------------------------------------------------------
%% Status helpers
%% ---------------------------------------------------------------------------

local_head(Chain) -> eth_chain:head(Chain).

local_head_num(Chain) ->
    case eth_chain:head(Chain) of
        {N, _} -> N;
        undefined -> 0
    end.

syncing_object(S, HeadN) ->
    case S#st.synced andalso HeadN >= S#st.target of
        true ->
            false;
        false ->
            #{<<"startingBlock">> => eth_hex:encode_int(max(S#st.start, 0)),
              <<"currentBlock">> => eth_hex:encode_int(HeadN),
              <<"highestBlock">> => eth_hex:encode_int(S#st.target)}
    end.