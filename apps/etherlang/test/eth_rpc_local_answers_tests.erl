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
%% net_version, eth_gasPrice, net_peerCount -- the three a status tool asks for
%% ---------------------------------------------------------------------------
%%
%% These had no clause in `dispatch/3', so they were refused with `-32601'. That is
%% the correct behaviour for a method this node does not implement -- the catch-all
%% policy is deliberate and is tested above -- and it still left the node unwatchable.
%% **Measured:** the eth-net-intelligence-api agent could not build its stats for
%% either node and the dashboard showed both offline.
%%
%% It does not report the absence usefully, which is the part worth recording.
%% web3 0.x turned the `-32601' into `Error: invalid argument 0: hex string without 0x
%% prefix', naming a *formatting* fault in this node's block responses -- and a scan of
%% all 27 string fields of `eth_getBlockByNumber' found none missing the prefix. The
%% hex complaint was three layers downstream of an unsupported method, so a reader who
%% believed it would have gone to the encoder.

%% `net_version' is the chain id as a **decimal** string, which is the whole difference
%% from `eth_chainId'. Asserted against `eth_fork_schedule:chain_id/0' rather than a
%% literal, so a network whose id is not Sepolia's does not need the test edited, and
%% asserted against `eth_chainId' so the two cannot report different chains.
net_version_is_the_chain_id_in_decimal_and_agrees_with_chain_id_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  Net = result(Port, <<"net_version">>, []),
                  Hex = result(Port, <<"eth_chainId">>, []),
                  %% **A binary, and a decimal string.** `integer_to_list/1' was the
                  %% first version and it answered an Erlang string -- a list of
                  %% character codes -- where every other result in this handler is a
                  %% binary, so the JSON encoder was handed a different shape for this
                  %% method alone. The test caught it as `binary_to_list("11155111")':
                  %% an argument printed as a string rather than as `<<"...">'.
                  ?assert(is_binary(Net)),
                  Expected = integer_to_list(eth_fork_schedule:chain_id()),
                  ?assertEqual(Expected, binary_to_list(Net)),
                  %% **The same number, not the same string.** `eth_chainId' is hex
                  %% (`0xaa36a7') and `net_version' is decimal (`11155111'), so
                  %% comparing the two as strings is wrong, and was: it failed with
                  %% expected `"0xaa36a7"' against value `"11155111"' -- two correct
                  %% answers to the same question. The expectations are bound to
                  %% variables first because `?assertEqual' on OTP 29 comes from
                  %% stdlib's `assert.hrl' and reads more naturally written inline.
                  ?assertEqual(eth_hex:decode(Hex), binary_to_integer(Net)),
                  %% Decimal, not hex. Asserted as `nomatch' rather than as
                  %% `assertNotEqual(nomatch, ...)', which asserts the *presence* of
                  %% "0x" -- the inverse of what this is about.
                  ?assertEqual(nomatch, binary:match(Net, <<"0x">>))
          end)
    end}.

%% `eth_gasPrice' now has a clause, so it answers instead of refusing.
%%
%% **The figure itself is asserted in `eth_rpc_extra_tests'
%% (`next_base_fee_for_head_reports_the_next_blocks_fee_not_the_heads_own_test_'),
%% and not here.** `eth_test_util:make_blocks/4' produces blocks with a
%% `baseFeePerGas' and a `gasLimit' but **no `gasUsed' at all**, so
%% `eth_rpc_projection:next_base_fee/1' falls to its pre-EIP-1559 clause and answers
%% `0' -- the figure the specification prescribes for a block that had no base fee. So
%% a value assertion written against this fixture would be satisfied by a correct
%% derivation and by a fabricated zero alike, and would pass for the wrong reason.
%% Building a `gasUsed'-bearing head here instead meant recomputing its hash, and
%% `eth_chain:append/2' rejected it with `bad_block_hash' -- a fixture defect, not a
%% finding.
%%
%% What this test can honestly say is that the method is answered and that its answer
%% has the shape of a quantity.
eth_gas_price_is_answered_and_is_a_hex_quantity_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  GasPrice = result(Port, <<"eth_gasPrice">>, []),
                  ?assert(is_binary(GasPrice)),
                  ?assertNotEqual(nomatch, binary:match(GasPrice, <<"0x">>))
          end)
    end}.

%% **An empty store has no next-block base fee, and the answer must say so.**
%%
%% `eth_rpc_projection:resolve_block_number/2' answers `max(head_num(Chain), 0)', so an
%% empty store and a head at block zero are the same answer -- and `next_base_fee/1' on
%% the resulting `#{}' returns `0', the figure the specification prescribes for a
%% pre-EIP-1559 block. So the empty-store case reached through it would have reported a
%% **gas price of zero**: a claim about the chain's next block derived from a fact about
%% this node's storage. Measured on the node with no upstream and an empty chain, which
%% is exactly that case -- every other read there answers `-32000 chain_empty'.
%% **The fallback must fire, and this is the only test that can see it.**
%%
%% The tests above run against a chain that *has* a head, so `next_base_fee_for_head/1'
%% answers and the fallback branch is never taken. Injecting the fallback away left the
%% whole module green -- measured, not assumed -- which is a gap in the tests rather than
%% a fact about the code.
%%
%% So this one runs on a chain with **no blocks at all**. With the fallback in place the
%% call goes upstream and fails, and the answer is the upstream's own failure code
%% (`-32603` with a `failed_connect` in the message). Without it the answer would be a
%% refusal invented here. **Asserting the code rather than "it is an error" is the point:
%% "an error" is true either way, and only the code says whose decision it was.**
eth_gas_price_falls_back_upstream_when_this_node_holds_no_head_test_() ->
    {timeout, 60, fun() ->
        ok = eth_test_util:start_apps(),
        Dead = eth_test_util:free_port(),
        {ok, _} = eth_chain:start_link('chain_gasprice', eth_test_util:tmp_dir()),
        Port = eth_test_util:free_port(),
        eth_rpc_client:init(#{url => "http://127.0.0.1:" ++ integer_to_list(Dead),
                              timeout_ms => 2000}),
        {ok, _} = eth_rpc_server:start_link('rpc_gasprice',
                                           #{port => Port, chain => 'chain_gasprice',
                                             sync => 'no_such_sync_name'}),
        try
            ?assertEqual(undefined, eth_chain:head('chain_gasprice')),
            {ok, Resp} = rpc(Port, call(<<"eth_gasPrice">>, [])),
            {ok, #{<<"error">> := Err}} = {ok, Resp},
            %% The upstream's code, not one of ours: a local refusal would be -32000 or
            %% -32601, and either would mean this node decided rather than asked.
            ?assertEqual(-32603, maps:get(<<"code">>, Err))
        after
            stop_quietly('rpc_gasprice'),
            stop_quietly('chain_gasprice')
        end
    end}.

an_empty_store_reports_no_local_head_rather_than_a_gas_price_of_zero_test_() ->
    {timeout, 60, fun() ->
        ok = eth_test_util:start_apps(),
        Dir = eth_test_util:tmp_dir(),
        {ok, _} = eth_chain:start_link('chain_empty_fee', Dir),
        try
            ?assertEqual({error, no_local_head},
                         eth_rpc_projection:next_base_fee_for_head('chain_empty_fee')),
            %% And the zero is not reachable by another route to the same function.
            ?assertNotEqual({ok, 0},
                            eth_rpc_projection:next_base_fee_for_head('chain_empty_fee'))
        after
            stop_quietly('chain_empty_fee')
        end
    end}.

%% `net_peerCount' with no peer manager and no peers is `0x0' -- a number, not a
%% refusal. `eth_peer:peers/0' exits when the manager is not running, so the count has
%% to survive that; the alternative would be a `-32601` on a method whose honest answer
%% is "zero".
net_peer_count_is_zero_when_there_are_no_peers_test_() ->
    {timeout, 60, fun() ->
        with_dead_upstream(
          fun(Port, _Blocks) ->
                  ?assertEqual(<<"0x0">>, result(Port, <<"net_peerCount">>, []))
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
