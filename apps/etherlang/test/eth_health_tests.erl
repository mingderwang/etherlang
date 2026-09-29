%% -*- erlang -*-
%% `GET /health`.
%%
%% The tests that matter here are the ones about **failure**, because an endpoint that
%% cannot say "no" is a decoration. A live component set is the easy half; what has to be
%% pinned is that a component which is *absent*, *wedged* or *not answering* produces 503
%% and a body that says which one, and that nothing in the report is a fabrication.
-module(eth_health_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% Over real HTTP, because the routing is the part that is easy to get wrong silently:
%% `"/"' is a catch-all, and a `/health' route listed after it is unreachable while still
%% appearing in the source. Asserting on `eth_health_handler:report/1' alone would pass
%% with the route in the wrong order, every time.

the_endpoint_is_reachable_and_is_not_the_json_rpc_handler_test_() ->
    {timeout, 60000, fun http_case/0}.

http_case() ->
    ok = eth_test_util:start_apps(),
    Mock = 'mock_health',
    Chain = 'chain_health',
    Mpt = uid('mpt_health_'),
    Sync = uid('sync_health_'),
    Pool = uid('pool_health_'),
    Server = 'rpc_health',
    Dir = eth_test_util:tmp_dir(),
    Port = eth_test_util:free_port(),
    {ok, _} = eth_mock_node:start_link(Mock),
    {ok, _} = eth_chain:start_link(Chain, Dir),
    _ = eth_health_fake:start(Mpt, [{size, 3}]),
    _ = eth_health_fake:start(Sync, [{status, false}]),
    _ = eth_health_fake:start(Pool, [{status, #{total => 1, pending => 1, queued => 0}}]),
    eth_rpc_client:init(#{url => eth_mock_node:url(Mock), timeout_ms => 10000}),
    %% All four probes are injected, so the listener starts **healthy** and the test can
    %% take it to unhealthy and back within one listener. Two listeners are not an option:
    %% each one starts the Engine API on `eth_config:engine_port/0`, so the second would
    %% be refused for a port that is already bound.
    {ok, _} = eth_rpc_server:start_link(Server, #{port => Port,
                                                 chain => Chain,
                                                 mpt => Mpt,
                                                 sync => Sync,
                                                 pool => Pool}),
    try
        %% ---- healthy: 200, and a body that is not a JSON-RPC envelope ----
        {200, Body} = get(Port, "/health"),
        %% If the route order is wrong this is `{"jsonrpc":"2.0","id":null,"error":...}`
        %% with a 200, which is the failure this assertion exists to catch: it looks like
        %% a working endpoint.
        ?assertNot(maps:is_key(<<"jsonrpc">>, Body)),
        ?assertEqual(<<"ok">>, maps:get(<<"status">>, Body)),
        Checks = maps:get(<<"checks">>, Body),
        [?assertEqual(true, maps:get(<<"ok">>, C)) || {_N, C} <- maps:to_list(Checks)],

        %% ---- the same URL, one component gone: 503, same shape ----
        ok = gen_server:stop(Pool),
        {503, Degraded} = get(Port, "/health"),
        ?assertEqual(<<"degraded: pool">>, maps:get(<<"status">>, Degraded)),
        ?assertNot(maps:is_key(<<"jsonrpc">>, Degraded)),
        %% The JSON-RPC port is still serving normally, which is the point of keeping this
        %% off the RPC path: a degraded node is not an unreachable one. The claim is that
        %% the catch-all still routes to the RPC handler, so the envelope is asserted and
        %% not the result -- this chain has no blocks in it and `eth_blockNumber'
        %% legitimately answers `chain_empty'.
        {200, #{<<"jsonrpc">> := <<"2.0">>, <<"id">> := 1}} =
            post(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                         <<"method">> => <<"eth_blockNumber">>, <<"params">> => []}),

        %% ---- and back ----
        %% `start/2` answers the name it registered, not `{ok, Pid}'. Matching `{ok, _}`
        %% here failed with `{badmatch, pool_health_71}`, which reads like a pid and is
        %% an atom.
        Pool = eth_health_fake:start(Pool, [{status, #{total => 0, pending => 0,
                                                       queued => 0}}]),
        {200, #{<<"status">> := <<"ok">>}} = get(Port, "/health"),

        %% Any other path 404s, and it is worth pinning because the reason `/health` is
        %% reachable at all is that cowboy_router matches **exact** paths: `"/"' is not a
        %% prefix catch-all. This was assumed the other way round and the test caught the
        %% assumption -- see the note on the route list in `eth_rpc_server'.
        {404, _} = get_raw(Port, "/healthz")
    after
        %% Cleanup that cannot raise. An `after` clause that *can* raise replaces the
        %% original failure with its own, which is how the real error here was invisible
        %% for several runs: `exit(Name, kill)` wants a pid and was handed a registered
        %% name, and the `badarg` it raised in the `after` is what eunit reported.
        stop_server(Server),
        kill(Chain), kill(Mpt), kill(Sync), kill(Pool)
    end.

%% **`gen_server:stop/1`, not `cowboy:stop_listener/1`.** Stopping the ranch listener
%% leaves the `eth_rpc_server' gen_server running, so `terminate/2' never executes and the
%% **Engine API listener stays bound on 8551** -- and every other test module in the suite
%% also starts a listener, so the next one is refused with
%% `{engine_api, {already_started, ...}}` and its test process dies, which eunit reports
%% as "unexpected termination of test process" and cancels the rest of the run. It did
%% exactly that to the full suite, twice, while this module passed alone. `terminate/2'
%% is where both listeners are released; this is the call that reaches it.
stop_server(Name) ->
    case whereis(Name) of
        undefined -> stop_listener(Name);
        Pid -> unlink(Pid), gen_server:stop(Pid)
    end.

stop_listener(Name) ->
    try cowboy:stop_listener(Name) catch _:_ -> ok end.

kill(Name) ->
    %% Unlink first. `exit(Pid, kill)` on a *linked* process takes this test process with
    %% it -- the kill is untrappable and propagates over the link -- which eunit reports
    %% as `unexpected termination of test process ::killed` and no assertion output at all.
    case whereis(Name) of
        undefined -> ok;
        Pid -> unlink(Pid), exit(Pid, kill)
    end.

%% ---------------------------------------------------------------------------
%% `report/1' against component processes this test controls, so that each failure mode
%% is produced rather than hoped for.

a_healthy_component_set_reports_ok_test() ->
    ok = eth_test_util:start_apps(),
    Report = eth_health_handler:report(#{chain => start_fake_chain(),
                                         mpt => start_fake_mpt(),
                                         sync => start_fake_sync(),
                                         pool => start_fake_pool()}),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Report)),
    Checks = maps:get(<<"checks">>, Report),
    [?assertEqual(true, maps:get(<<"ok">>, C)) || {_N, C} <- maps:to_list(Checks)].

%% The default for `mpt' is the real singleton. Asserted as *the default name* rather than
%% as "the singleton is not running", because the second is not available here and the
%% difference is instructive: this test passed alone and failed in the full suite, because
%% other modules start `eth_mpt` for their own fixtures. A test whose outcome depends on
%% execution order is testing the suite's schedule, not the code.
%%
%% What is available, and what this is actually for, is that omitting `mpt' probes exactly
%% what passing `mpt => eth_mpt' probes. That holds whether or not it is running.
omitting_the_trie_from_the_options_probes_the_real_singleton_test() ->
    Chain = start_fake_chain(),
    Sync = start_fake_sync(),
    Pool = start_fake_pool(),
    ?assertEqual(eth_health_handler:report(#{chain => Chain, mpt => eth_mpt,
                                             sync => Sync, pool => Pool}),
                 eth_health_handler:report(#{chain => Chain, sync => Sync, pool => Pool})).

a_component_that_does_not_answer_degrades_the_node_test() ->
    ok = eth_test_util:start_apps(),
    Chain = start_fake_chain(),
    Pool = start_fake_pool(),
    %% The name is not registered, which is what a node whose sync worker failed to start
    %% looks like from here.
    Report = eth_health_handler:report(#{chain => Chain, mpt => start_fake_mpt(),
                                         sync => 'no_such_sync', pool => Pool}),
    ?assertEqual(<<"degraded: sync">>, maps:get(<<"status">>, Report)),
    Sync0 = maps:get(<<"sync">>, maps:get(<<"checks">>, Report)),
    ?assertEqual(false, maps:get(<<"ok">>, Sync0)),
    ?assertEqual(<<"not running">>, maps:get(<<"error">>, Sync0)).

a_component_that_is_wedged_is_a_failure_and_not_a_pass_test() ->
    %% **This is the case an `is_process_alive/1' probe would report as healthy.** The
    %% fake chain answers `head' and then stops answering everything, so the process is
    %% alive and the node cannot serve. If this test ever reports `ok', the probe has
    %% become a liveness check wearing a readiness check's name.
    ok = eth_test_util:start_apps(),
    Chain = start_wedged_chain(),
    Report = eth_health_handler:report(#{chain => Chain, mpt => start_fake_mpt(),
                                         sync => 'no_such_sync', pool => 'no_such_pool'}),
    Checks = maps:get(<<"checks">>, Report),
    ?assertEqual(false, maps:get(<<"ok">>, maps:get(<<"chain">>, Checks))),
    ?assertEqual(<<"timeout">>, maps:get(<<"error">>, maps:get(<<"chain">>, Checks))),
    ?assertMatch(<<"degraded: ", _/binary>>, maps:get(<<"status">>, Report)).

a_node_with_no_head_reports_zero_and_not_a_failure_test() ->
    %% `head' is `undefined' before the first block is stored. That is a normal state for
    %% a node that has not synced, and reporting it as unhealthy would make the endpoint
    %% useless for exactly the period an orchestrator most wants to watch.
    ok = eth_test_util:start_apps(),
    Chain = start_fake_chain(undefined),
    Report = eth_health_handler:report(#{chain => Chain, mpt => start_fake_mpt(),
                                         sync => 'no_such_sync', pool => 'no_such_pool'}),
    Chain0 = maps:get(<<"chain">>, maps:get(<<"checks">>, Report)),
    ?assertEqual(true, maps:get(<<"ok">>, Chain0)),
    ?assertEqual(<<"0x0">>, maps:get(<<"head">>, Chain0)),
    ?assertEqual(null, maps:get(<<"headHash">>, Chain0)).

the_report_states_the_head_and_the_pool_and_nothing_it_cannot_know_test() ->
    ok = eth_test_util:start_apps(),
    Hash = <<16#aa, 16#bb, 16#cc>>,
    Chain = start_fake_chain({4242, Hash}),
    Pool = start_fake_pool(),
    Report = eth_health_handler:report(#{chain => Chain, mpt => start_fake_mpt(),
                                         sync => 'no_such_sync', pool => Pool}),
    Checks = maps:get(<<"checks">>, Report),
    ?assertEqual(<<"0x1092">>, maps:get(<<"head">>, maps:get(<<"chain">>, Checks))),
    ?assertEqual(<<"0xaabbcc">>, maps:get(<<"headHash">>, maps:get(<<"chain">>, Checks))),
    ?assertEqual(2, maps:get(<<"pending">>, maps:get(<<"pool">>, Checks))),
    ?assertEqual(3, maps:get(<<"queued">>, maps:get(<<"pool">>, Checks))).

%% The report names a `stateRoot` nowhere, and there is no field that could be read as
%% one. AGENTS.md §4.1 is that there is no way to get a bare root out of this codebase
%% on purpose; a health endpoint is not a place to add one, and a test is cheaper than a
%% review comment.
the_report_carries_no_state_root_test() ->
    ok = eth_test_util:start_apps(),
    Report = eth_health_handler:report(#{chain => start_fake_chain(),
                                         mpt => start_fake_mpt(),
                                         sync => 'no_such_sync',
                                         pool => 'no_such_pool'}),
    Text = iolist_to_binary(thoas:encode(Report)),
    ?assertEqual(nomatch, string:find(Text, "stateRoot")),
    ?assertEqual(nomatch, string:find(Text, "state_root")).

%% ---------------------------------------------------------------------------
%% Fakes live in `eth_health_fake'. Three trivial gen_servers, so the probes are
%% exercised without a chain store, a trie, an upstream, or the supervision tree.

zero() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

uid(Prefix) -> list_to_atom(atom_to_list(Prefix) ++
                           integer_to_list(erlang:unique_integer([positive]))).

start_fake_chain() -> start_fake_chain({0, zero()}).

start_fake_chain(Head) ->
    eth_health_fake:start(uid('fake_chain_'),
                          [{head, Head}, {highest, 99}, {size, 7}]).

start_fake_mpt() ->
    eth_health_fake:start(uid('fake_mpt_'), [{size, 3}]).

start_fake_sync() ->
    eth_health_fake:start(uid('fake_sync_'), [{status, false}]).

start_fake_pool() ->
    eth_health_fake:start(uid('fake_pool_'),
                          [{status, #{total => 5, pending => 2, queued => 3}}]).

%% Answers `head' and then never answers anything again.
start_wedged_chain() -> eth_health_fake:start_wedged(uid('wedged_chain_')).

%% ---------------------------------------------------------------------------
%% HTTP

%% `thoas:decode/1` answers `{ok, Term}' and both helpers **unwrap** it. They did not at
%% first, so `get/2` returned `{200, {ok, Body}}' and every assertion in the HTTP case
%% failed with `{badmap, {ok, ...}}' -- against an endpoint that was answering 200 with
%% `status: ok` and all five checks green. A helper that returns its own wrapper is a
%% small thing that looks like a product defect.
get(Port, Path) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    {ok, {{_, Code, _}, _, Resp}} =
        httpc:request(get, {URL, []}, [{timeout, 10000}], [{body_format, binary}]),
    {Code, decode(Resp)}.

post(Port, Body) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(Port),
    {ok, {{_, Code, _}, _, Resp}} =
        httpc:request(post, {URL, [], "application/json", thoas:encode(Body)},
                      [{timeout, 10000}], [{body_format, binary}]),
    {Code, decode(Resp)}.

decode(Bin) ->
    {ok, Term} = thoas:decode(Bin),
    Term.

get_raw(Port, Path) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    {ok, {{_, Code, _}, _, Resp}} =
        httpc:request(get, {URL, []}, [{timeout, 10000}], [{body_format, binary}]),
    {Code, Resp}.
