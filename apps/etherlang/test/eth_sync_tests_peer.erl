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
        {NumBlocks, NumReceipts} = consistent(Blocks0),
        ok = eth_chain:append(chain_ps_srv, pair_blocks(NumBlocks)),
        ok = lists:foldl(fun({N, Rs}, ok) ->
            eth_chain:put_receipts(chain_ps_srv, N, Rs)
        end, ok, NumReceipts),
        ExpectHead = {5, maps:get(<<"hash">>, element(2, lists:nth(6, NumBlocks)))},
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
            ok = wait_receipts(chain_ps_con, 5, 2, 200),
            %% Full bodies arrived too (not header-only stubs).
            {ok, Got, true} = eth_chain:get_by_number(chain_ps_con, 5),
            ?assertEqual(2, length(maps:get(<<"transactions">>, Got))),
            ?assert(is_map(hd(maps:get(<<"transactions">>, Got)))),
            %% Receipts were fetched, verified, and stored.
            {ok, Stored} = eth_chain:receipts(chain_ps_con, 5),
            ?assertEqual(2, length(Stored)),
            [Tx5 | _] = maps:get(<<"transactions">>, Got),
            {ok, 5} = eth_chain:tx_block(chain_ps_con, maps:get(<<"hash">>, Tx5))
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

wait_receipts(_Chain, _Num, _Count, 0) -> error(peer_receipts_timeout);
wait_receipts(Chain, Num, Count, N) ->
    case eth_chain:receipts(Chain, Num) of
        {ok, Rs} when length(Rs) =:= Count -> ok;
        _ -> timer:sleep(100), wait_receipts(Chain, Num, Count, N - 1)
    end.

pair_blocks(NumBlocks) ->
    [{Num, B, true} || {Num, B} <- NumBlocks].

%% Fixture blocks with transactionsRoot/receiptsRoot/hash/parentHash
%% recomputed so bodies AND receipts verify (fixtures ship zero roots).
%% Returns {Blocks, [{Num, Receipts}]}.
consistent(Blocks) ->
    {Out, Rcts, _} = lists:foldl(fun(B, {Acc, RAcc, Parent}) ->
        Txs = maps:get(<<"transactions">>, B),
        {ok, TxRoot} = eth_tx:tx_root(Txs),
        Receipts = receipts_for(Txs),
        {ok, RcRoot} = eth_receipt:receipt_root(Receipts),
        B1 = B#{<<"parentHash">> => Parent,
                <<"transactionsRoot">> => hex0x(TxRoot),
                <<"receiptsRoot">> => hex0x(RcRoot)},
        {ok, H} = eth_header:hash(B1),
        B2 = B1#{<<"hash">> => hex0x(H)},
        Num = eth_hex:decode(maps:get(<<"number">>, B2)),
        {[{Num, B2} | Acc], [{Num, Receipts} | RAcc], hex0x(H)}
    end, {[], [], z0()}, Blocks),
    {lists:reverse(Out), lists:reverse(Rcts)}.

receipts_for(Txs) ->
    {Rs, _} = lists:foldl(fun(Tx, {Acc, Cum}) ->
        Gas = tx_gas(Tx),
        {[#{<<"type">> => <<"0x0">>, <<"status">> => <<"0x1">>,
             <<"cumulative_gas_used">> => eth_hex:encode_int(Cum + Gas),
             <<"logs">> => []} | Acc], Cum + Gas}
    end, {[], 0}, Txs),
    lists:reverse(Rs).

tx_gas(#{<<"gas">> := G}) ->
    try eth_hex:decode(G) catch _:_ -> 21000 end;
tx_gas(_) -> 21000.

hex0x(Bin) ->
    <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

stop(Name) -> (try gen_server:stop(Name) catch _:_ -> ok end).
