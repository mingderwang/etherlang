-module(eth_eth_tests).

-include_lib("eunit/include/eunit.hrl").

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

negotiate_test() ->
    ?assertMatch({ok, #{version := 68, base := 16}},
                 eth_eth:negotiate([{<<"eth">>, 68}])),
    ?assertMatch({ok, #{version := 67, base := 16}},
                 eth_eth:negotiate([{<<"eth">>, 67}])),
    ?assertEqual({error, no_eth}, eth_eth:negotiate([])),
    ?assertEqual({error, no_eth}, eth_eth:negotiate([{<<"snap">>, 1}])),
    ?assertMatch({error, {eth_too_old, _}},
                 eth_eth:negotiate([{<<"eth">>, 63}])).

status_roundtrip_test() ->
    S = #{version => 68, network => 11155111, td => 17000000000000000,
          best => crypto:strong_rand_bytes(32), best_number => 1735371,
          head_time => 1677557088,
          genesis => eth_eth:genesis_hash(),
          fork_hash => <<0, 0, 0, 0>>, fork_next => 0},
    {ok, Dec} = eth_eth:decode_status(eth_eth:encode_status(S)),
    Local = #{head_number => 1735371, head_time => 1677557088},
    %% Same-hash peers accept (rule 1b); fork fields round-trip opaque here
    %% (strict ForkID vectors live in eth_forkid_tests).
    ?assertEqual(maps:with([version, network, td, best, genesis],
                           S#{best_number => 1735371}),
                 maps:with([version, network, td, best, genesis], Dec)),
    ?assertMatch({error, {network_mismatch, _}},
                 eth_eth:check_status(Local, Dec#{network => 1})),
    ?assertEqual({error, genesis_mismatch},
                 eth_eth:check_status(Local,
                                      Dec#{genesis => crypto:strong_rand_bytes(32)})),
    ?assertEqual({error, bad_status}, eth_eth:decode_status([1, 2])).

headers_codec_test() ->
    Req = eth_eth:encode_get_headers({number, 10}, 5, 0, false),
    {ok, {number, 10}, 5, 0, false} =
        eth_eth:decode_get_headers_bin(eth_rlp:encode(Req)),
    ReqH = eth_eth:encode_get_headers({hash, crypto:strong_rand_bytes(32)},
                                      5, 2, true),
    {ok, {hash, _}, 5, 2, true} =
        eth_eth:decode_get_headers_bin(eth_rlp:encode(ReqH)),
    ?assertEqual({error, bad_headers_req},
                 eth_eth:decode_get_headers_bin(eth_rlp:encode([1]))).

with_chain(Name, Count, Fun) ->
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(Name, Dir),
    try
        {_H, Blocks} = eth_test_util:make_blocks(0, Count, z0(), 0),
        ok = eth_chain:append(Name,
                              [{N, B, true} || {N, B} <-
                                  [{eth_hex:decode(maps:get(<<"number">>, B)), B}
                                   || B <- Blocks]]),
        Fun(Blocks)
    after
        gen_server:stop(Name)
    end.

serve_test() ->
    with_chain(chain_serve_a, 6, fun(Blocks) ->
        %% Forward from 1, three headers.
        {ok, Hdrs} = eth_eth:serve_headers(chain_serve_a, {number, 1}, 3, 0, false),
        ?assertEqual(3, length(Hdrs)),
        ?assertEqual([1, 2, 3], [header_num(H) || H <- Hdrs]),
        ?assertEqual(ok, eth_eth:verify_chain(Hdrs, true)),
        %% Skip 1 from 0: 0, 2, 4 (not adjacency-linked; well-formed only).
        {ok, Skipped} = eth_eth:serve_headers(chain_serve_a, {number, 0}, 3, 1, false),
        ?assertEqual([0, 2, 4], [header_num(H) || H <- Skipped]),
        ?assertEqual(ok, eth_eth:verify_chain(Skipped, true, 1)),
        %% Reverse from 4, two headers: 4, 3.
        {ok, Rev} = eth_eth:serve_headers(chain_serve_a, {number, 4}, 2, 0, true),
        ?assertEqual([4, 3], [header_num(H) || H <- Rev]),
        ?assertEqual(ok, eth_eth:verify_chain(Rev, false)),
        %% Hash ref resolves.
        H3 = maps:get(<<"hash">>, lists:nth(4, Blocks)),
        {ok, ByHash} = eth_eth:serve_headers(chain_serve_a,
                                             {hash, hex_to_bin(H3)}, 2, 0, false),
        ?assertEqual([3, 4], [header_num(H) || H <- ByHash]),
        %% Beyond highest: empty (still valid).
        ?assertEqual({ok, []},
                     eth_eth:serve_headers(chain_serve_a, {number, 99}, 3, 0, false)),
        %% Unknown hash: error.
        ?assertMatch({error, _},
                     eth_eth:serve_headers(chain_serve_a,
                                           {hash, crypto:strong_rand_bytes(32)},
                                           3, 0, false)),
        %% Tampered linkage is rejected.
        [A, B | Rest] = Hdrs,
        Tampered = [<<0:256>> | tl(B)],
        ?assertEqual({error, broken_linkage},
                     eth_eth:verify_chain([A, Tampered | Rest], true))
    end).

header_num(RLPHeader) ->
    case lists:nth(9, RLPHeader) of
        I when is_integer(I) -> I;
        B when is_binary(B) -> binary:decode_unsigned(B)
    end.

bodies_test() ->
    with_chain(chain_bodies_a, 6, fun(Blocks) ->
        H3 = maps:get(<<"hash">>, lists:nth(4, Blocks)),
        {ok, [Body]} = eth_eth:serve_bodies(chain_bodies_a,
                                            [hex_to_bin(H3)]),
        [Txs, Uncles] = Body,
        %% Fixture blocks carry two legacy transactions, no uncles.
        ?assertEqual(2, length(Txs)),
        ?assertEqual([], Uncles),
        %% Unknown hash serves empty (geth-compatible).
        {ok, [[]]} = eth_eth:serve_bodies(chain_bodies_a,
                                          [crypto:strong_rand_bytes(32)]),
        %% Bodies codec round-trips through RLP.
        {ok, [Body]} = eth_eth:decode_bodies_bin(
                         eth_rlp:encode([Body])),
        %% Craft headers carrying the true roots: verification passes...
        {ok, [H]} = eth_eth:serve_headers(chain_bodies_a, {number, 3}, 1, 0, false),
        {ok, Root} = eth_eth:bodies_tx_root(Body),
        H1 = set_header_root(H, Root),
        ?assertEqual(ok, eth_eth:verify_bodies([H1], [Body])),
        %% ...and rejects mismatched roots.
        ?assertEqual({error, body_mismatch},
                     eth_eth:verify_bodies([H], [Body])),
        ?assertEqual({error, count_mismatch},
                     eth_eth:verify_bodies([H1, H1], [Body]))
    end).

%% Replace the transactionsRoot field (index 4) of a decoded header.
set_header_root(Header, Root) ->
    {Pre, [_ | Post]} = lists:split(4, Header),
    Pre ++ [Root | Post].

hex_to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
hex_to_bin(H) -> binary:decode_hex(H).

%% Block hash of a decoded header RLP list.
block_hash(Header) ->
    eth_keccak:hash(eth_rlp:encode(Header)).

%% Full eth handshake + header fetch between two connections over loopback.
interop_test_() ->
    {timeout, 60, fun interop/0}.

interop() ->
    %% No upstream here: fail the TD lookup fast (retries=0) so Status
    %% falls back to the compat constant instead of burning backoff.
    eth_rpc_client:init(#{url => "http://127.0.0.1:1", timeout_ms => 1000,
                          retries => 0, backoff_ms => 10}),
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(chain_eth_ab, Dir),
    try
        {_, Blocks} = eth_test_util:make_blocks(0, 6, z0(), 0),
        ok = eth_chain:append(chain_eth_ab, pair(Blocks)),
        PrivA = eth_secp256k1:generate_key(),
        PrivB = eth_secp256k1:generate_key(),
        IDA = eth_ecies:pubkey(PrivA),
        IDB = eth_ecies:pubkey(PrivB),
        {ok, LS} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
                                      {reuseaddr, true}]),
        {ok, Port} = inet:port(LS),
        Parent = self(),
        spawn(fun() ->
            {ok, Sock} = gen_tcp:accept(LS, 8000),
            {ok, Pid} = eth_peer_conn:start_recipient(
                          Parent, Sock, args(PrivB, undefined, IDB, chain_eth_ab)),
            %% The acceptor owns the socket; hand it to the conn before
            %% exiting or the socket dies with us.
            ok = gen_tcp:controlling_process(Sock, Pid),
            Parent ! {recp, Pid}
        end),
        {ok, PidA} = eth_peer_conn:start_initiator(
                       Parent, {{127, 0, 0, 1}, Port},
                       args(PrivA, IDB, IDA, chain_eth_ab)),
        PidB = receive {recp, P} -> P after 8000 -> error(acceptor_timeout) end,
        receive {peer_up, PidA, IDB, _} -> ok after 8000 -> error(a_no_peer_up) end,
        receive {peer_up, PidB, IDA, _} -> ok after 8000 -> error(b_no_peer_up) end,
        %% Both sides negotiated eth.
        #{eth := EthA} = gen_server:call(PidA, status),
        ?assertMatch(#{version := 68}, EthA),
        %% Fetch 1..3 across the wire.
        {ok, Hdrs} = gen_server:call(PidA, {get_headers, {number, 1}, 3, 0, false},
                                     20000),
        ?assertEqual([1, 2, 3], [header_num(H) || H <- Hdrs]),
        %% Reverse fetch.
        {ok, Rev} = gen_server:call(PidA, {get_headers, {number, 3}, 2, 0, true},
                                    20000),
        ?assertEqual([3, 2], [header_num(H) || H <- Rev]),
        %% Beyond head: empty but valid.
        ?assertEqual({ok, []},
                     gen_server:call(PidA, {get_headers, {number, 99}, 3, 0, false},
                                     20000)),
        %% Bodies fetch across the wire: block 1 has two fixture txs.
        {ok, Heads} = gen_server:call(PidA, {get_headers, {number, 1}, 2, 0, false},
                                      20000),
        Hashes = [block_hash(H) || H <- Heads],
        {ok, Bodies} = gen_server:call(PidA, {get_bodies, Hashes}, 20000),
        ?assertEqual(2, length(Bodies)),
        ?assertEqual([2, 2], [length(Txs) || [Txs, _] <- Bodies]),
        %% Roots recompute stably over the wire terms.
        Roots1 = [begin {ok, R} = eth_eth:bodies_tx_root(B), R end || B <- Bodies],
        {ok, Bodies2} = eth_eth:decode_bodies_bin(eth_rlp:encode(Bodies)),
        Roots2 = [begin {ok, R} = eth_eth:bodies_tx_root(B), R end || B <- Bodies2],
        ?assertEqual(Roots1, Roots2),
        gen_server:stop(PidA),
        gen_server:stop(PidB),
        gen_tcp:close(LS)
    after
        (try gen_server:stop(chain_eth_ab) catch _:_ -> ok end)
    end.

pair(Blocks) ->
    [{eth_hex:decode(maps:get(<<"number">>, B)), B, true} || B <- Blocks].

args(Priv, RemoteID, ID, Chain) ->
    #{privkey => Priv, remote_id => RemoteID, node_id => ID,
      client_id => <<"test">>, caps => eth_eth:caps(), listen_port => 0,
      chain => Chain}.
