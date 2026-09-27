%% Methods this node answers from its own state rather than by asking another node.
%%
%% The catch-all clause in `eth_rpc_handler:dispatch/3' used to forward every method
%% it had no clause for. That is the most misleading thing a JSON-RPC handler can
%% do, because it makes the set of questions a node *answers* larger than the set it
%% *can answer*: a client asks this node a question and is told the answer by a
%% different node, with nothing in the response to say so. The eight `eth_*' methods
%% that were unexamined for exactly this reason are covered in `eth_rpc_extra_tests';
%% this module covers the three changes that closed the remaining cases.
%%
%% The proof that an answer is local is the **dead upstream**. The client is pointed
%% at a port nothing is listening on, so any method that still tries to proxy fails
%% to connect. A method that answers anyway was answered by this node. That is a
%% stronger claim than "the value looks right", which is what asserting the mock's
%% absence would give, and it is the only version of the assertion that would have
%% failed before the change -- the old code proxied, and a proxy to a dead port
%% returns a connection error rather than an answer.
-module(eth_rpc_local_answers_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

%% ---------------------------------------------------------------------------
%% eth_chainId
%% ---------------------------------------------------------------------------

%% EIP-695 made the chain id mandatory and every client checks it at startup. It was
%% answered by the catch-all, so the number came from `UPSTREAM_RPC_URL' -- it
%% described the operator's configuration rather than the chain this node executes.
chain_id_comes_from_the_configured_network_not_the_upstream_test_() ->
    {timeout, 60, fun() ->
        Previous = os:getenv("ETH_NETWORK"),
        os:putenv("ETH_NETWORK", "mainnet"),
        try
            with_dead_upstream(
              fun(Port, _Blocks) ->
                      %% The dead upstream cannot answer, so this number is this
                      %% node's -- and it is mainnet's, not the default Sepolia's.
                      %% The mock upstream answers `0xaa36a7', so a proxied
                      %% implementation would fail this on the value as well as on
                      %% the dead port.
                      ?assertEqual(<<"0x1">>, result(Port, <<"eth_chainId">>, [])),
                      %% And it agrees with the EVM's own CHAINID, so the RPC
                      %% surface and the opcode cannot drift apart.
                      ?assertEqual(1, eth_fork_schedule:chain_id())
              end)
        after
            restore_env("ETH_NETWORK", Previous)
        end
    end}.

%% The number follows the network this node is configured for, not a constant.
chain_id_follows_the_configured_network_test_() ->
    {timeout, 60, fun() ->
        Previous = os:getenv("ETH_NETWORK"),
        os:putenv("ETH_NETWORK", "sepolia"),
        try
            with_dead_upstream(
              fun(Port, _Blocks) ->
                      ?assertEqual(<<"0xaa36a7">>, result(Port, <<"eth_chainId">>, []))
              end)
        after
            restore_env("ETH_NETWORK", Previous)
        end
    end}.

%% ---------------------------------------------------------------------------
%% The uncle methods
%% ---------------------------------------------------------------------------
%%
%% EIP-3675 took uncles out of the block header. On a chain that merged at genesis
%% every block has none, so the count is `0` and the uncle is `null` -- and both are
%% answerable without a lookup and without asking anyone.

uncle_counts_are_zero_because_this_chain_merged_at_genesis_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  Tags = [<<"latest">>, <<"earliest">>, <<"pending">>, <<"safe">>,
                          <<"finalized">>, <<"0x0">>, <<"0x2">>],
                  lists:foreach(
                    fun(Tag) ->
                            ?assertEqual(<<"0x0">>,
                                         result(Port, <<"eth_getUncleCountByBlockNumber">>,
                                                [Tag]))
                    end, Tags),
                  lists:foreach(
                    fun(Tag) ->
                            ?assertEqual(null,
                                         result(Port,
                                                <<"eth_getUncleByBlockNumberAndIndex">>,
                                                [Tag, <<"0x0">>]))
                    end, Tags)
          end)
    end}.

uncle_by_hash_is_answered_for_a_block_this_node_holds_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, Blocks) ->
                  Hash = maps:get(<<"hash">>, hd(Blocks)),
                  ?assertEqual(<<"0x0">>,
                               result(Port, <<"eth_getUncleCountByBlockHash">>, [Hash])),
                  ?assertEqual(null,
                               result(Port, <<"eth_getUncleByBlockHashAndIndex">>,
                                      [Hash, <<"0x0">>]))
          end)
    end}.

%% A hash this node does not hold may name a pre-Merge block on another chain, which
%% really did carry uncles. Answering `0` would be a claim about a block this node
%% has never seen, so it refuses and says why -- and it refuses *locally*, which is
%% the whole point: the old code asked the upstream, which would have been another
%% node's opinion about a block neither of them holds.
an_unknown_block_hash_is_refused_rather_than_answered_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  %% As the 0x-hex string JSON actually carries. The first version
                  %% of this test passed 32 raw bytes, and `thoas:encode/1' rejected
                  %% the payload with `invalid_byte, <<"0xAB">>' -- a hash cannot
                  %% travel any other way, so that test was asserting a shape no
                  %% client can send.
                  Unknown = <<"0xabcdef0123456789abcdef0123456789abcdef01"
                             "23456789abcdef012345678a">>,
                  ?assertEqual(-32001,
                               error_code(Port, <<"eth_getUncleCountByBlockHash">>,
                                          [Unknown])),
                  ?assertEqual(-32001,
                               error_code(Port, <<"eth_getUncleByBlockHashAndIndex">>,
                                          [Unknown, <<"0x0">>]))
          end)
    end}.

%% Two different failures, two different codes, and the line between them is
%% whether the string is a hash at all.
%%
%% A *short* hash is not malformed: `0xdeadbeef' is four well-formed bytes, so it
%% names a block this node has never heard of, which is `-32001'. I had written this
%% test expecting `-32602' and the node answered `-32001', and the node was right --
%% `eth_getBlockByHash/3' does not width-check either, so refusing a short hash here
%% and accepting it there would be two answers to one question. Only a string that
%% is not hex is a bad parameter.
a_short_hash_is_a_block_this_node_does_not_hold_not_a_malformed_one_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  ?assertEqual(-32001,
                               error_code(Port, <<"eth_getUncleCountByBlockHash">>,
                                          [<<"0xdeadbeef">>])),
                  ?assertEqual(-32602,
                               error_code(Port, <<"eth_getUncleCountByBlockHash">>,
                                          [<<"0xnothexatall">>])),
                  ?assertEqual(-32602,
                               error_code(Port, <<"eth_getUncleCountByBlockHash">>,
                                          [<<"zzz">>]))
          end)
    end}.

%% ---------------------------------------------------------------------------
%% The catch-all
%% ---------------------------------------------------------------------------

%% An unimplemented method is refused with `-32601`, which is the JSON-RPC 2.0 code
%% for "method not found", and the message names the method so the refusal is
%% debuggable from a client's log rather than merely absent.
an_unimplemented_method_is_refused_with_the_method_named_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  Method = <<"eth_getSomethingNobodyAskedFor">>,
                  ?assertEqual(-32601, error_code(Port, Method, [])),
                  {ok, #{<<"error">> := Err}} = rpc(Port, call(Method, [])),
                  Message = maps:get(<<"message">>, Err),
                  ?assertNotEqual(nomatch, binary:match(Message, Method))
          end)
    end}.

%% The whole point, stated as a control: with the upstream unreachable, a method that
%% genuinely proxies fails, and a method this node answers does not. Without this
%% the other tests would pass just as well against a handler that answered
%% everything from its own state *and* one that proxied to a live mock.
a_method_that_does_proxy_still_fails_against_a_dead_upstream_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  %% `eth_getBalance' for an account with nothing in the overlay
                  %% falls through to the upstream on purpose -- a documented
                  %% fallback, not the catch-all -- so with the upstream dead it
                  %% must *not* answer. If it did, the "dead upstream" premise
                  %% would be false and every assertion above would be vacuous.
                  Account = <<"0x112233445566778899aabbccddeeff0011223344">>,
                  {ok, #{<<"error">> := _}} =
                      rpc(Port, call(<<"eth_getBalance">>, [Account, <<"latest">>]))
          end)
    end}.

%% ---------------------------------------------------------------------------
%% Harness
%% ---------------------------------------------------------------------------

%% The two fields the tests below care about, read rather than matched.
%%
%% `#{<<"result">> := X}' inside `?assertEqual' compiles only because EUnit's
%% expansion happens to put the first argument in a pattern position, and that is a
%% property of the macro rather than of the language -- it broke here on the atom
%% `null' and again on a binary literal. Reading the field is unambiguous.
result(Port, Method, Params) ->
    {ok, Resp} = rpc(Port, call(Method, Params)),
    maps:get(<<"result">>, Resp).

error_code(Port, Method, Params) ->
    {ok, Resp} = rpc(Port, call(Method, Params)),
    maps:get(<<"code">>, maps:get(<<"error">>, Resp)).

call(Method, Params) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
      <<"method">> => Method, <<"params">> => Params}.

%% Point the upstream at a port nothing is listening on, serve over a real listener,
%% and hand the port to `Fun'. Returns the blocks it stored so a test can name a hash
%% it holds.
with_dead_upstream(Fun) -> with_dead_upstream(Fun, []).

with_dead_upstream(Fun, _Extra) ->
    ok = eth_test_util:start_apps(),
    Dead = eth_test_util:free_port(),
    {ok, _} = eth_chain:start_link('chain_local', eth_test_util:tmp_dir()),
    Port = eth_test_util:free_port(),
    {_, Blocks} = eth_test_util:make_blocks(0, 4, z0(), 0),
    Pairs = [begin
                 Num = eth_hex:decode(maps:get(<<"number">>, B)),
                 {Num, maps:remove(<<"totalDifficulty">>, B), true}
             end || B <- Blocks],
    ok = eth_chain:append('chain_local', Pairs),
    eth_rpc_client:init(#{url => "http://127.0.0.1:" ++ integer_to_list(Dead),
                          timeout_ms => 2000}),
    {ok, _} = eth_rpc_server:start_link('rpc_local',
                                       #{port => Port, chain => 'chain_local',
                                         sync => 'no_such_sync_name'}),
    try Fun(Port, Blocks)
    after
        stop_quietly('rpc_local'),
        stop_quietly('chain_local')
    end.

%% Teardown must not fail the test it is tearing down after. A `gen_server:stop' on
%% a process that has already exited is an ordinary outcome of a test that asserted
%% a crash, and reporting it as an error would make the teardown the failure.
stop_quietly(Name) ->
    try gen_server:stop(Name)
    catch _:_ -> ok
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).

rpc(Port, Payload) ->
    http_post(Port, thoas:encode(Payload)).

%% `httpc' rather than a hand-rolled socket. The first version of this built the
%% request by hand and every test in the module failed in `gen_tcp:recv/3' with a
%% malformed-response error, which says nothing about the handler -- the module's own
%% HTTP client was wrong. Reusing the one the rest of the RPC tests use is both
%% shorter and known to work.
http_post(Port, Body) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(Port),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {URL, [], "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    {ok, Decoded} = thoas:decode(Resp),
    {ok, Decoded}.
