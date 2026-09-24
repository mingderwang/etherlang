-module(eth_txpool_tests).

-include_lib("eunit/include/eunit.hrl").

%% Sign a legacy tx map (without v/r/s) with Priv, EIP-155 style.
sign_legacy(Priv, Tx) -> sign_legacy(Priv, Tx, 11155111).
sign_legacy(Priv, Tx, ChainID) ->
    F = [q(<<"nonce">>, Tx), q(<<"gasPrice">>, Tx), q(<<"gas">>, Tx),
         addr(maps:get(<<"to">>, Tx, <<>>)), q(<<"value">>, Tx),
         data(maps:get(<<"input">>, Tx, <<>>))],
    Digest = eth_keccak:hash(eth_rlp:encode(F ++ [ChainID, 0, 0])),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx#{<<"chainId">> => eth_hex:encode_int(ChainID),
        <<"v">> => eth_hex:encode_int(V + 35 + 2 * ChainID),
        <<"r">> => eth_hex:encode_int(R),
        <<"s">> => eth_hex:encode_int(S)}.

q(K, Tx) -> qty(maps:get(K, Tx, 0)).
qty(I) when is_integer(I) -> I;
qty(B) when is_binary(B) ->
    try eth_hex:decode(B) catch _:_ -> 0 end.

addr(<<"0x", R/binary>>) -> binary:decode_hex(R);
addr(B) when is_binary(B), byte_size(B) =:= 40 -> binary:decode_hex(B);
addr(_) -> <<>>.
data(<<"0x", R/binary>>) -> binary:decode_hex(R);
data(_) -> <<>>.

base_tx() ->
    #{<<"nonce">> => <<"0x0">>, <<"gasPrice">> => <<"0x3b9aca00">>,
      <<"gas">> => <<"0x5208">>,
      <<"to">> => <<"0x1000000000000000000000000000000000000001">>,
      <<"value">> => <<"0x0">>, <<"input">> => <<"0x">>,
      <<"chainId">> => <<"0xaa36a7">>}.

funded_state(Addr, Balance, Nonce) ->
    S0 = eth_state:new(#{}, #{}),
    S2 = eth_state:set_balance(S0, Addr, Balance),
    eth_state:set_nonce(S2, Addr, Nonce).

bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

%% Real Sepolia tx recovers its `from`.
sender_vector_test() ->
    Path = filename:join([filename:dirname(?FILE), "vectors",
                          "sepolia_1735460.json"]),
    {ok, Bin} = file:read_file(Path),
    {ok, #{<<"result">> := Block}} = thoas:decode(Bin),
    [Tx | _] = maps:get(<<"transactions">>, Block),
    {ok, Sender} = eth_tx:sender(Tx),
    ?assertEqual(maps:get(<<"from">>, Tx),
                 <<"0x", (string:lowercase(binary:encode_hex(Sender)))/binary>>).

add_accept_test() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_accept}),
    try
        Priv = eth_secp256k1:generate_key(),
        ID = eth_ecies:pubkey(Priv),
        Addr = bin0x(addr_bin(ID)),
        State = funded_state(Addr, 1000000000000000000, 0),
        Tx = sign_legacy(Priv, base_tx()),
        {ok, Raw} = eth_tx:to_rlp(Tx),
        {ok, Hash} = eth_txpool:add_raw(pool_accept, Raw),
        ?assert(eth_txpool:has(pool_accept, Hash)),
        ?assertEqual(1, length(eth_txpool:pending(pool_accept))),
        ?assertEqual(0, length(eth_txpool:queued(pool_accept))),
        %% Duplicate add is idempotent.
        ?assertEqual({ok, Hash}, eth_txpool:add_raw(pool_accept, Raw)),
        %% Same tx validates against funded state explicitly too.
        {ok, Hash} = eth_txpool:add_map(pool_accept, Tx, State)
    after
        gen_server:stop(pool_accept)
    end.

reject_test() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_reject}),
    try
        Priv = eth_secp256k1:generate_key(),
        ID = eth_ecies:pubkey(Priv),
        Addr = bin0x(addr_bin(ID)),
        Rich = funded_state(Addr, 1000000000000000000, 5),
        Poor = funded_state(Addr, 1, 0),
        Good = sign_legacy(Priv, base_tx()),
        {ok, GoodBin} = eth_tx:to_rlp(Good),
        %% Wrong chain (signed for mainnet).
        BadChain = sign_legacy(Priv, base_tx(), 1),
        {ok, BadChainBin} = eth_tx:to_rlp(BadChain#{<<"chainId">> => <<"0x1">>}),
        ?assertMatch({error, _}, eth_txpool:add_raw(pool_reject, BadChainBin)),
        %% Unprotected legacy (v 27/28).
        Unprot = Good#{<<"v">> => <<"0x1b">>},
        {ok, UnprotBin} = eth_tx:to_rlp(Unprot),
        ?assertMatch({error, _}, eth_txpool:add_raw(pool_reject, UnprotBin)),
        %% Stale nonce.
        ?assertMatch({error, nonce_too_low},
                     eth_txpool:add_map(pool_reject, Good, Rich)),
        %% Insufficient balance.
        ?assertMatch({error, insufficient_balance},
                     eth_txpool:add_map(pool_reject, Good, Poor)),
        %% Zero gas.
        ZeroGas = sign_legacy(Priv, (base_tx())#{<<"gas">> => <<"0x0">>}),
        {ok, ZeroGasBin} = eth_tx:to_rlp(ZeroGas),
        ?assertMatch({error, _}, eth_txpool:add_raw(pool_reject, ZeroGasBin)),
        %% Garbage bytes.
        ?assertMatch({error, _}, eth_txpool:add_raw(pool_reject, <<1, 2, 3>>)),
        %% Sanity: good tx with exact-nonce state passes.
        Exact = funded_state(Addr, 1000000000000000000, 0),
        ?assertMatch({ok, _}, eth_txpool:add_map(pool_reject, Good, Exact)),
        _ = GoodBin,
        ok
    after
        gen_server:stop(pool_reject)
    end.

nonce_order_test() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_order}),
    try
        Priv = eth_secp256k1:generate_key(),
        ID = eth_ecies:pubkey(Priv),
        Addr = bin0x(addr_bin(ID)),
        State = funded_state(Addr, 1000000000000000000000000, 0),
        Add = fun(N) ->
            Tx = sign_legacy(Priv, (base_tx())#{<<"nonce">> => eth_hex:encode_int(N)}),
            {ok, Bin} = eth_tx:to_rlp(Tx),
            {ok, _} = eth_txpool:add_raw(pool_order, Bin)
        end,
        Add(0), Add(2),
        ?assertEqual(1, length(eth_txpool:pending(pool_order))),
        ?assertEqual(1, length(eth_txpool:queued(pool_order))),
        Add(1),
        ?assertEqual(3, length(eth_txpool:pending(pool_order))),
        ?assertEqual(0, length(eth_txpool:queued(pool_order))),
        _ = State,
        ok
    after
        gen_server:stop(pool_order)
    end.

evict_test() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_evict, max => 3,
                                      per_sender => 100}),
    try
        Mk = fun(Price) ->
            Priv = eth_secp256k1:generate_key(),
            Tx = sign_legacy(Priv, (base_tx())#{<<"gasPrice">> => eth_hex:encode_int(Price)}),
            {ok, Bin} = eth_tx:to_rlp(Tx),
            {ok, Hash} = eth_txpool:add_raw(pool_evict, Bin),
            {Price, Hash}
        end,
        [{_, H1}, {_, H2}, {_, H3}] = [Mk(10), Mk(20), Mk(30)],
        ?assertEqual(3, maps:get(total, eth_txpool:status(pool_evict))),
        %% Cheapest newcomer still fits (4th slot? no: max 3, evicts lowest).
        {_, H4} = Mk(5),
        ?assertEqual(3, maps:get(total, eth_txpool:status(pool_evict))),
        ?assertNot(eth_txpool:has(pool_evict, H4)),
        ?assert(eth_txpool:has(pool_evict, H1)),
        ?assert(eth_txpool:has(pool_evict, H2)),
        ?assert(eth_txpool:has(pool_evict, H3))
    after
        gen_server:stop(pool_evict)
    end.

per_sender_cap_test() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_cap, max => 1000,
                                      per_sender => 2}),
    try
        Priv = eth_secp256k1:generate_key(),
        lists:foreach(fun(N) ->
            Tx = sign_legacy(Priv, (base_tx())#{<<"nonce">> => eth_hex:encode_int(N)}),
            {ok, Bin} = eth_tx:to_rlp(Tx),
            {ok, _} = eth_txpool:add_raw(pool_cap, Bin)
        end, [0, 1, 2]),
        ?assertEqual(2, maps:get(total, eth_txpool:status(pool_cap)))
    after
        gen_server:stop(pool_cap)
    end.

refresh_drop_test() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_refresh}),
    try
        Priv = eth_secp256k1:generate_key(),
        ID = eth_ecies:pubkey(Priv),
        Addr = bin0x(addr_bin(ID)),
        Tx = sign_legacy(Priv, base_tx()),
        {ok, Bin} = eth_tx:to_rlp(Tx),
        {ok, _} = eth_txpool:add_raw(pool_refresh, Bin),
        ?assertEqual(1, maps:get(total, eth_txpool:status(pool_refresh))),
        %% Chain moved past nonce 0: refresh drops it as stale.
        NewState = funded_state(Addr, 1000000000000000000, 1),
        ok = eth_txpool:set_state(pool_refresh, NewState),
        ?assertEqual(0, maps:get(total, eth_txpool:status(pool_refresh)))
    after
        gen_server:stop(pool_refresh)
    end.

addr_bin(ID64) ->
    binary:part(eth_keccak:hash(ID64), 12, 20).

z0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.

%% eth_sendRawTransaction validates, pools, and returns the hash.
rpc_test_() ->
    {timeout, 60, fun rpc/0}.

rpc() ->
    eth_test_util:start_apps(),
    {ok, _} = eth_txpool:start_link(#{name => pool_rpc}),
    Port = eth_test_util:free_port(),
    {ok, _} = eth_rpc_server:start_link(srv_txpool,
                                        #{port => Port, pool => pool_rpc,
                                          sync => 'no_such_sync_name'}),
    try
        Priv = eth_secp256k1:generate_key(),
        Tx = sign_legacy(Priv, base_tx()),
        {ok, Bin} = eth_tx:to_rlp(Tx),
        Raw = <<"0x", (binary:encode_hex(Bin))/binary>>,
        {ok, #{<<"result">> := Hash}} =
            post(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                         <<"method">> => <<"eth_sendRawTransaction">>,
                         <<"params">> => [Raw]}),
        ?assert(eth_txpool:has(pool_rpc, Hash)),
        %% Bad hex.
        {ok, #{<<"error">> := _}} =
            post(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2,
                         <<"method">> => <<"eth_sendRawTransaction">>,
                         <<"params">> => [<<"0xzzzz">>]}),
        %% Well-formed RLP but invalid tx (zero gas).
        BadTx = sign_legacy(Priv, (base_tx())#{<<"gas">> => <<"0x0">>}),
        {ok, BadBin} = eth_tx:to_rlp(BadTx),
        BadRaw = <<"0x", (binary:encode_hex(BadBin))/binary>>,
        {ok, #{<<"error">> := _}} =
            post(Port, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3,
                         <<"method">> => <<"eth_sendRawTransaction">>,
                         <<"params">> => [BadRaw]})
    after
        gen_server:stop(srv_txpool),
        gen_server:stop(pool_rpc)
    end.

post(Port, Payload) ->
    Body = thoas:encode(Payload),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {"http://127.0.0.1:" ++ integer_to_list(Port),
                             [{"content-type", "application/json"}],
                             "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    thoas:decode(Resp).

%% Gossip loopback: A broadcasts a pooled hash, B fetches, validates,
%% and pools it — all through real conns.
gossip_test_() ->
    {timeout, 60, fun gossip/0}.

gossip() ->
    eth_rpc_client:init(#{url => "http://127.0.0.1:1", timeout_ms => 1000,
                          retries => 0, backoff_ms => 10}),
    Dir = eth_test_util:tmp_dir(),
    {ok, _} = eth_chain:start_link(chain_gos, Dir),
    try
        {_, Blocks} = eth_test_util:make_blocks(0, 2, z0(), 0),
        ok = eth_chain:append(chain_gos, pair(Blocks)),
        PrivA = eth_secp256k1:generate_key(),
        PrivB = eth_secp256k1:generate_key(),
        IDA = eth_ecies:pubkey(PrivA),
        IDB = eth_ecies:pubkey(PrivB),
        {ok, _} = eth_txpool:start_link(#{name => pool_gos_a}),
        {ok, _} = eth_txpool:start_link(#{name => pool_gos_b}),
        {ok, LS} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
                                      {reuseaddr, true}]),
        {ok, Port} = inet:port(LS),
        Parent = self(),
        spawn(fun() ->
            {ok, Sock} = gen_tcp:accept(LS, 8000),
            {ok, Pid} = eth_peer_conn:start_recipient(
                          Parent, Sock, conn_args(PrivB, IDB, pool_gos_b)),
            ok = gen_tcp:controlling_process(Sock, Pid),
            Parent ! {recp, Pid}
        end),
        {ok, PidA} = eth_peer_conn:start_initiator(
                       Parent, {{127, 0, 0, 1}, Port},
                       conn_args(PrivA, IDA, pool_gos_a, IDB)),
        PidB = receive {recp, P} -> P after 8000 -> error(acceptor_timeout) end,
        receive {peer_up, PidA, IDB, _} -> ok after 8000 -> error(a_no_up) end,
        receive {peer_up, PidB, IDA, _} -> ok after 8000 -> error(b_no_up) end,
        %% A pools a signed tx, then announces it.
        SPriv = eth_secp256k1:generate_key(),
        STx = sign_legacy(SPriv, base_tx()),
        {ok, SBin} = eth_tx:to_rlp(STx),
        {ok, SHash} = eth_txpool:add_raw(pool_gos_a, SBin),
        SHRaw = hex_to_bin(SHash),
        gen_server:cast(PidA, {broadcast_hashes, [SHRaw]}),
        ok = wait_pool(pool_gos_b, SHash, 100),
        gen_server:stop(PidA),
        gen_server:stop(PidB),
        gen_tcp:close(LS)
    after
        (try gen_server:stop(pool_gos_a) catch _:_ -> ok end),
        (try gen_server:stop(pool_gos_b) catch _:_ -> ok end),
        (try gen_server:stop(chain_gos) catch _:_ -> ok end)
    end.

wait_pool(_Pool, _Hash, 0) -> error(gossip_timeout);
wait_pool(Pool, Hash, N) ->
    case eth_txpool:has(Pool, Hash) of
        true -> ok;
        false -> timer:sleep(100), wait_pool(Pool, Hash, N - 1)
    end.

conn_args(Priv, ID, Pool) ->
    #{privkey => Priv, remote_id => undefined, node_id => ID,
      client_id => <<"test">>, caps => eth_eth:caps(), listen_port => 0,
      chain => chain_gos, pool => Pool}.
conn_args(Priv, ID, Pool, RemoteID) ->
    (conn_args(Priv, ID, Pool))#{remote_id => RemoteID}.

hex_to_bin(<<"0x", R/binary>>) -> binary:decode_hex(R).

pair(Blocks) ->
    [{eth_hex:decode(maps:get(<<"number">>, B)), B, true} || B <- Blocks].
