-module(eth_peer_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

%% Full loopback: discA bonds discB over UDP, peerA auto-dials B over TCP
%% from discA's table, both sides complete the eth handshake. peerB stays
%% passive (target 0) so exactly one connection forms.
autodial_test_() ->
    {timeout, 90, fun autodial/0}.

autodial() ->
    eth_rpc_client:init(#{url => "http://127.0.0.1:1", timeout_ms => 1000,
                          retries => 0, backoff_ms => 10}),
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(chain_ad_ab, Dir),
    try
        {_, Blocks} = eth_test_util:make_blocks(0, 3, z0(), 0),
        ok = eth_chain:append(chain_ad_ab, pair(Blocks)),
        PrivA = eth_secp256k1:generate_key(),
        PrivB = eth_secp256k1:generate_key(),
        %% B uses one fixed port for UDP discovery and TCP RLPx (the
        %% production shape: a single enode port serves both).
        BPort = eth_test_util:free_port(),
        {ok, _} = eth_discv4:start_link(#{name => disc_ad_b, port => BPort,
                                          privkey => PrivB, bootnodes => []}),
        #{port := UdpB, id := IDB} = eth_discv4:status(disc_ad_b),
        EnodeB = lists:flatten(io_lib:format("enode://~s@127.0.0.1:~p",
                                             [binary_to_list(binary:encode_hex(IDB)),
                                              UdpB])),
        {ok, _} = eth_discv4:start_link(#{name => disc_ad_a, port => 0,
                                          privkey => PrivA,
                                          bootnodes => [EnodeB]}),
        {ok, _} = eth_peer:start_link(#{name => peer_ad_b, port => BPort,
                                        privkey => PrivB, disc => disc_ad_b,
                                        target => 0, interval => 200,
                                        chain => chain_ad_ab}),
        {ok, _} = eth_peer:start_link(#{name => peer_ad_a, port => 0,
                                        privkey => PrivA, disc => disc_ad_a,
                                        target => 2, interval => 200,
                                        chain => chain_ad_ab}),
        try
            ok = wait_eth_peer(peer_ad_a, IDB, 200),
            %% Exactly one connection to B (no duplicate dials).
            ?assertEqual(1, count_remote(peer_ad_a, IDB)),
            %% Headers flow over the auto-dialed connection.
            {ok, Hdrs} = eth_peer:get_headers(peer_ad_a, {number, 0}, 2, 0, false),
            ?assertEqual([0, 1], [header_num(H) || H <- Hdrs])
        after
            stop(peer_ad_a), stop(peer_ad_b),
            stop(disc_ad_a), stop(disc_ad_b)
        end
    after
        (try gen_server:stop(chain_ad_ab) catch _:_ -> ok end)
    end.

%% No discovery source: no tick, no dials, listener still works.
no_disc_test() ->
    {ok, _} = eth_peer:start_link(#{name => peer_nodisc, port => 0,
                                    privkey => eth_secp256k1:generate_key()}),
    try
        timer:sleep(300),
        #{peers := 0} = eth_peer:status(peer_nodisc)
    after
        stop(peer_nodisc)
    end.

wait_eth_peer(_Name, _ID, 0) -> error(autodial_timeout);
wait_eth_peer(Name, ID, N) ->
    Infos = eth_peer:peers(Name),
    case [P || {P, I} <- Infos, is_map(I),
               maps:get(eth, I, false) =/= false,
               maps:get(remote, I, undefined) =:= ID] of
        [_ | _] -> ok;
        [] -> timer:sleep(100), wait_eth_peer(Name, ID, N - 1)
    end.

count_remote(Name, ID) ->
    Infos = eth_peer:peers(Name),
    length([P || {P, I} <- Infos, is_map(I),
                 maps:get(remote, I, undefined) =:= ID]).

header_num(H) ->
    case lists:nth(9, H) of
        I when is_integer(I) -> I;
        B when is_binary(B) -> binary:decode_unsigned(B)
    end.

pair(Blocks) ->
    [{eth_hex:decode(maps:get(<<"number">>, B)), B, true} || B <- Blocks].

stop(Name) -> (try gen_server:stop(Name) catch _:_ -> ok end).
