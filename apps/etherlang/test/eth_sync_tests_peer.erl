-module(eth_sync_tests_peer).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

%% Peer-first sync: consumer with an empty chain syncs headers+bodies from
%% a serving stack over loopback (disc + RLPx + eth), no upstream RPC.
peer_sync_test_() ->
    {timeout, 90, fun peer_sync/0}.

peer_sync() ->
    eth_rpc_client:init(#{url => "http://127.0.0.1:1", timeout_ms => 1000,
                          retries => 0, backoff_ms => 10}),
    DirS = eth_test_util:tmp_dir(),
    DirC = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(chain_ps_srv, DirS),
    {ok, _} = eth_chain:start_link(chain_ps_con, DirC),
    try
        {_, Blocks0} = eth_test_util:make_blocks(0, 6, z0(), 0),
        Blocks = consistent(Blocks0),
        ok = eth_chain:append(chain_ps_srv, pair(Blocks)),
        ExpectHead = {5, maps:get(<<"hash">>, lists:nth(6, Blocks))},
        PrivA = eth_secp256k1:generate_key(),
        PrivB = eth_secp256k1:generate_key(),
        BPort = eth_test_util:free_port(),
        {ok, _} = eth_discv4:start_link(#{name => disc_ps_b, port => BPort,
                                          privkey => PrivB, bootnodes => []}),
        #{port := UdpB, id := IDB} = eth_discv4:status(disc_ps_b),
        EnodeB = lists:flatten(io_lib:format("enode://~s@127.0.0.1:~p",
                                             [binary_to_list(binary:encode_hex(IDB)),
                                              UdpB])),
        {ok, _} = eth_discv4:start_link(#{name => disc_ps_a, port => 0,
                                          privkey => PrivA,
                                          bootnodes => [EnodeB]}),
        {ok, _} = eth_peer:start_link(#{name => peer_ps_b, port => BPort,
                                        privkey => PrivB, disc => disc_ps_b,
                                        target => 0, interval => 200,
                                        chain => chain_ps_srv}),
        {ok, _} = eth_peer:start_link(#{name => peer_ps_a, port => 0,
                                        privkey => PrivA, disc => disc_ps_a,
                                        target => 2, interval => 200,
                                        chain => chain_ps_con}),
        {ok, _} = eth_sync:start_link(sync_ps,
                                      #{chain => chain_ps_con,
                                        peer_mgr => peer_ps_a,
                                        concurrency => 4,
                                        body_window => 2048,
                                        poll_interval_ms => 200,
                                        sync_retry_ms => 100,
                                        max_reorg_depth => 256,
                                        sync_budget => 2048,
                                        start_block => latest}),
        try
            ok = wait_head(chain_ps_con, ExpectHead, 400),
            %% Full bodies arrived too (not header-only stubs).
            {ok, Got, true} = eth_chain:get_by_number(chain_ps_con, 5),
            ?assertEqual(2, length(maps:get(<<"transactions">>, Got))),
            ?assert(is_map(hd(maps:get(<<"transactions">>, Got))))
        after
            stop(sync_ps),
            stop(peer_ps_a), stop(peer_ps_b),
            stop(disc_ps_a), stop(disc_ps_b)
        end
    after
        (try gen_server:stop(chain_ps_srv) catch _:_ -> ok end),
        (try gen_server:stop(chain_ps_con) catch _:_ -> ok end)
    end.

wait_head(_Chain, _Expect, 0) -> error(peer_sync_timeout);
wait_head(Chain, Expect, N) ->
    case eth_chain:head(Chain) of
        Expect -> ok;
        _ -> timer:sleep(100), wait_head(Chain, Expect, N - 1)
    end.

pair(Blocks) ->
    [{eth_hex:decode(maps:get(<<"number">>, B)), B, true} || B <- Blocks].

%% Fixture blocks with transactionsRoot/hash/parentHash recomputed so
%% bodies verify against headers (fixtures ship zero roots).
consistent(Blocks) ->
    {Out, _} = lists:foldl(fun(B, {Acc, Parent}) ->
        {ok, Root} = eth_tx:tx_root(maps:get(<<"transactions">>, B)),
        B1 = B#{<<"parentHash">> => Parent,
                <<"transactionsRoot">> => hex0x(Root)},
        {ok, H} = eth_header:hash(B1),
        B2 = B1#{<<"hash">> => hex0x(H)},
        {[B2 | Acc], hex0x(H)}
    end, {[], z0()}, Blocks),
    lists:reverse(Out).

hex0x(Bin) ->
    <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

stop(Name) -> (try gen_server:stop(Name) catch _:_ -> ok end).
