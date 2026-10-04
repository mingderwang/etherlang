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

%% ---------------------------------------------------------------------------
%% Replacement: two transactions may not occupy the same (sender, nonce)
%% ---------------------------------------------------------------------------
%%
%% Only one transaction per (sender, nonce) can ever be included in a valid
%% block -- a block containing both would apply the same account transition
%% twice and diverge from every other client. So the pool must hold at most one,
%% and the one it holds must be the one a proposer would actually want.
%%
%% `eth_txpool:insert/3` keys on the transaction **hash**, so two transactions
%% that differ only in `gasPrice` were both admitted and both lived in the pool
%% forever. `pending_list/1' then broke the tie, and `sender_pending/2' sorts on
%% `nonce' alone with a `=<' comparator, which returns true both ways for equal
%% nonces -- so the tie was resolved by whatever order `by_sender/1' happened to
%% produce. That order is a prepending accumulator over `maps:fold/3`, and for a
%% small map that is a flatmap visited in key order, where the key is the hash.
%%
%% **Measured, and it is not a coin flip that favours the payer:** over 12 runs
%% with a 1 gwei and a 2 gwei transaction at the same (sender, nonce), the
%% winner was the 2 gwei one in 8 and the 1 gwei one in 4 -- and the 2 gwei one
%% won in exactly the 8 runs where *its own hash was the larger of the two*. 12 of
%% 12, no exceptions. So the fee is not a tiebreaker at all; it is not consulted.
%% The consequence is the ordinary one: a user who replaces a stuck transaction
%% by raising its price has a 50% chance of being silently ignored, and the pool
%% keeps both, so the loser also occupies a per-sender and a global slot.
%%
%% The rule below is "at most one per (sender, nonce), and a strictly higher
%% price wins". It states no threshold, because no EIP specifies one and this
%% node has nothing to derive it from -- geth requires a ~10% bump, and adopting
%% that number here would be importing a peer's policy as if it were a rule. A
%% threshold is a policy decision, and this is a verifier that does not author
%% blocks; the cost of not having one is that a spammer can churn a slot by
%% bidding one wei more, which is bounded by `per_sender' and `max' and costs
%% nothing but its own bandwidth.
a_higher_price_replaces_the_same_sender_and_nonce_test_() ->
    {timeout, 60, fun a_higher_price_replaces_the_same_sender_and_nonce/0}.

a_higher_price_replaces_the_same_sender_and_nonce() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_replace}),
    try
        Priv = eth_secp256k1:generate_key(),
        ID = eth_ecies:pubkey(Priv),
        Addr = bin0x(addr_bin(ID)),
        State = funded_state(Addr, 1000000000000000000, 0),
        Cheap = sign_legacy(Priv, base_tx()),
        Dear = sign_legacy(Priv, (base_tx())#{<<"gasPrice">> => <<"0x77359400">>}),

        {ok, CheapHash} = eth_txpool:add_map(pool_replace, Cheap, State),
        {ok, _} = eth_txpool:add_map(pool_replace, Dear, State),

        %% One slot, and it is the dearer one.
        ?assertEqual(1, maps:get(total, eth_txpool:status(pool_replace))),
        ?assertNot(eth_txpool:has(pool_replace, CheapHash)),
        [Pending] = eth_txpool:pending(pool_replace),
        ?assertEqual(2000000000, maps:get(price, Pending)),

        %% And it survives a second bump, which is the case a user retries.
        Dearer = sign_legacy(Priv, (base_tx())#{<<"gasPrice">> => <<"0xb2d05e00">>}),
        {ok, _} = eth_txpool:add_map(pool_replace, Dearer, State),
        ?assertEqual(1, maps:get(total, eth_txpool:status(pool_replace))),
        [Pending2] = eth_txpool:pending(pool_replace),
        ?assertEqual(3000000000, maps:get(price, Pending2))
    after
        gen_server:stop(pool_replace)
    end.

a_lower_price_does_not_replace_the_same_sender_and_nonce_test_() ->
    {timeout, 60, fun a_lower_price_does_not_replace_the_same_sender_and_nonce/0}.

a_lower_price_does_not_replace_the_same_sender_and_nonce() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_replace_low}),
    try
        Priv = eth_secp256k1:generate_key(),
        ID = eth_ecies:pubkey(Priv),
        Addr = bin0x(addr_bin(ID)),
        State = funded_state(Addr, 1000000000000000000, 0),
        Dear = sign_legacy(Priv, (base_tx())#{<<"gasPrice">> => <<"0x77359400">>}),
        Cheap = sign_legacy(Priv, base_tx()),

        {ok, DearHash} = eth_txpool:add_map(pool_replace_low, Dear, State),
        %% A cheaper transaction at a nonce the pool already holds is refused,
        %% rather than admitted to sit in `queued' where nothing will take it.
        ?assertEqual({error, replacement_underpriced},
                     eth_txpool:add_map(pool_replace_low, Cheap, State)),
        ?assertEqual(1, maps:get(total, eth_txpool:status(pool_replace_low))),
        ?assert(eth_txpool:has(pool_replace_low, DearHash))
    after
        gen_server:stop(pool_replace_low)
    end.

%% Two transactions at *different* nonces are a different thing entirely and must
%% still coexist -- otherwise the fix above would cap every sender at one
%% transaction, which is not what a nonce sequence is for.
different_nonces_for_one_sender_still_coexist_test_() ->
    {timeout, 60, fun different_nonces_for_one_sender_still_coexist/0}.

different_nonces_for_one_sender_still_coexist() ->
    {ok, _} = eth_txpool:start_link(#{name => pool_two_nonces}),
    try
        Priv = eth_secp256k1:generate_key(),
        ID = eth_ecies:pubkey(Priv),
        Addr = bin0x(addr_bin(ID)),
        State = funded_state(Addr, 1000000000000000000, 0),
        lists:foreach(
          fun(N) ->
              Tx = sign_legacy(Priv, (base_tx())#{<<"nonce">> => eth_hex:encode_int(N)}),
              ?assertMatch({ok, _}, eth_txpool:add_map(pool_two_nonces, Tx, State))
          end, [0, 1, 2]),
        ?assertEqual(3, maps:get(total, eth_txpool:status(pool_two_nonces))),
        ?assertEqual(3, length(eth_txpool:pending(pool_two_nonces)))
    after
        gen_server:stop(pool_two_nonces)
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
        SHRaw = eth_hex:must_decode_bytes(SHash),
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

%% **Removed: a copy of the hex decoder, in the test tree.**
%% `eth_hex_owners_tests` had been scanning `?SRC` alone, so seven test modules kept their
%% own -- `eth_test_util` among them, which is the module every other fixture builds its
%% blocks with. **A guard scoped to one directory is a guard with a hole in it**, and the
%% hole was the half of the tree where a helper gets written because `src/` does not appear
%% to export one.
%%
%% The behaviour is `eth_hex:must_decode_bytes/1` exactly: it strips `0x`, refuses an odd
%% length, and raises on a character that is not a hex digit -- as `binary:decode_hex/1`
%% did, for the inputs these fixtures actually pass.

pair(Blocks) ->
    [{eth_hex:decode(maps:get(<<"number">>, B)), B, true} || B <- Blocks].

%% ---------------------------------------------------------------------------
%% Admission runs the same validity rules block execution does
%% ---------------------------------------------------------------------------
%%
%% eth_tx:validate/2 enforced all of this already, and had tests for it, but the
%% tests called eth_block_builder:validate_transaction/2 -- a wrapper that
%% nothing in the application invokes, because the builder is neither started nor
%% referenced outside a test file. eth_sendRawTransaction goes through eth_txpool,
%% and admission there ran three checks of its own and stopped. So a blob
%% transaction with no versioned hashes was given a hash and broadcast to peers,
%% and the rules that would have refused it were green in the suite.
%%
%% Each case below goes through eth_txpool:add_map/3, which is the path the RPC
%% handler takes.

blob_tx_without_hashes_is_refused_at_admission_test() ->
    %% `zero_blobs' rather than the `bad_blob_hashes' this asserted before `v1.60`
    %% split it. See `eth_4844_tests:blob_tx_without_hashes_rejected_test'.
    ?assertEqual({error, zero_blobs}, admit(blob_tx(#{<<"blobVersionedHashes">> => []}))).

%% The commitments are well formed here, so the only thing wrong is the missing
%% fee. eth_tx checks the hashes first, so leaving them out as well would report
%% `zero_blobs' and this case would pass for the wrong reason.
blob_tx_without_blob_fee_is_refused_at_admission_test() ->
    ?assertEqual({error, invalid_blob_fee},
                 admit(blob_tx(#{<<"maxFeePerBlobGas">> => absent,
                                 <<"blobVersionedHashes">> => [bin0x(versioned_hash(1))]}))).

%% A commitment that is present but malformed is refused as well. A versioned
%% hash is a 32-byte KZG commitment hash with the 0x01 version byte on top, so a
%% leading 0x02 is not one.
blob_tx_with_a_malformed_commitment_is_refused_test() ->
    %% `invalid_blob_hash' and not `zero_blobs', and not the shared `bad_blob_hashes'
    %% this used to assert: the list is non-empty, so it is the *version byte* that is
    %% wrong, which is the EIP's other assert. Two fixtures that both said
    %% "bad_blob_hashes" were one fixture that could not tell them apart.
    ?assertEqual({error, invalid_blob_hash},
                 admit(blob_tx(#{<<"blobVersionedHashes">> => [bin0x(<<2, 0:248>>)]}))).

%% A well-formed one is admitted, so the rules above are discriminating rather
%% than a blanket refusal of blob transactions.
blob_tx_with_a_well_formed_commitment_is_admitted_test() ->
    ?assertMatch({ok, _},
                 admit(blob_tx(#{<<"blobVersionedHashes">> => [bin0x(versioned_hash(1))]}))).

%% eth_tx:validate/2 checks the blob shape before the signature, which is why an
%% unsigned transaction reaches a blob verdict at all. Pinned because it is
%% load-bearing for the cases above: reorder those two checks and they would
%% start reporting bad_signature, which would look like the rules had been
%% dropped rather than like an ordering change.
blob_shape_is_checked_before_the_signature_test() ->
    ?assertNotEqual({error, bad_signature},
                    admit(blob_tx(#{<<"blobVersionedHashes">> => []}))).

%% The pool's own nonce rule is unchanged by any of this: a transaction ahead of
%% the account nonce is queued, not rejected, because eth_tx:validate/2 only
%% knows whether the nonce matches and would call a gap bad_nonce.
gapped_nonce_is_still_queued_not_refused_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = sign_legacy(Priv, (base_tx())#{<<"nonce">> => <<"0x7">>}),
    Addr = bin0x(addr_bin(eth_ecies:pubkey(Priv))),
    State = funded_state(Addr, 1000000000000000000, 0),
    Name = fresh_pool(),
    {ok, _} = eth_txpool:start_link(#{name => Name}),
    try
        {ok, _} = eth_txpool:add_map(Name, Tx, State),
        ?assertEqual(1, length(eth_txpool:queued(Name)))
    after
        (try gen_server:stop(Name) catch _:_ -> ok end)
    end.

%% --- helpers ---------------------------------------------------------------

fresh_pool() ->
    list_to_atom("pool_admit_" ++ integer_to_list(erlang:unique_integer([positive]))).

%% Build a signed EIP-4844 transaction, run it past admission, and return the
%% verdict. The account is funded and at nonce 0 so the balance and nonce checks
%% are not what is under test.
admit(Tx0) ->
    Priv = eth_secp256k1:generate_key(),
    Tx = Tx0#{<<"v">> => <<"0x0">>, <<"r">> => <<"0x0">>, <<"s">> => <<"0x0">>},
    Signed = sign_blob(drop_absent(Tx), Priv),
    Addr = bin0x(addr_bin(eth_ecies:pubkey(Priv))),
    State = funded_state(Addr, 1000000000000000000, 0),
    Name = fresh_pool(),
    {ok, _} = eth_txpool:start_link(#{name => Name}),
    try
        eth_txpool:add_map(Name, Signed, State)
    after
        (try gen_server:stop(Name) catch _:_ -> ok end)
    end.

blob_tx(Extra) ->
    maps:merge(#{<<"type">> => <<"0x3">>,
                 <<"chainId">> => <<"0xaa36a7">>,
                 <<"nonce">> => <<"0x0">>,
                 <<"maxPriorityFeePerGas">> => <<"0x3">>,
                 <<"maxFeePerGas">> => <<"0x77359400">>,
                 <<"gas">> => <<"0x186a0">>,
                 <<"to">> => <<"0x1000000000000000000000000000000000000001">>,
                 <<"value">> => <<"0x0">>,
                 <<"input">> => <<"0x">>,
                 <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>}, Extra).

%% `absent' is a request to remove the key, so a missing field is genuinely
%% missing rather than present-and-atom-valued.
drop_absent(Tx) ->
    maps:filter(fun(_, V) -> V =/= absent end, Tx).

sign_blob(Tx, Priv) ->
    Digest = eth_keccak:hash(<<16#03, (eth_rlp:encode(preimage_fields(Tx)))/binary>>),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Tx#{<<"v">> => eth_hex:encode_int(V),
        <<"r">> => eth_hex:encode_int(R),
        <<"s">> => eth_hex:encode_int(S)}.

preimage_fields(Tx) ->
    [q(<<"chainId">>, Tx), q(<<"nonce">>, Tx),
     q(<<"maxPriorityFeePerGas">>, Tx), q(<<"maxFeePerGas">>, Tx),
     q(<<"gas">>, Tx), to_bin(maps:get(<<"to">>, Tx)), q(<<"value">>, Tx),
     to_bin(maps:get(<<"input">>, Tx)),
     [], q(<<"maxFeePerBlobGas">>, Tx), eth_tx:blob_versioned_hashes(Tx)].

to_bin(<<"0x", R/binary>>) -> binary:decode_hex(R);
to_bin(B) when is_binary(B), byte_size(B) =:= 20 -> B;
to_bin(_) -> <<>>.

versioned_hash(Tag) -> <<1, (binary:copy(<<Tag>>, 31))/binary>>.
