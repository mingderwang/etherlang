-module(eth_snap_tests).

-include_lib("eunit/include/eunit.hrl").

%% Build {trie, key->rlp} fixture: 4 accounts with storage roots + codes.
fixture() ->
    Accts = [{I, mk_acct(I)} || I <- lists:seq(0, 3)],
    %% key = keccak(<<I>>), value = RLP account
    Pairs = [{eth_keccak:hash(<<I:256>>), eth_rlp:encode(A)} || {I, A} <- Accts],
    Tree = eth_trie:build(Pairs),
    Root = eth_trie:root(Pairs),
    {Root, Tree, Pairs}.

mk_acct(I) ->
    [I, I * 1000,
     <<I:256>>,
     eth_keccak:hash(<<I:8>>)].

account_verify_test() ->
    {Root, Tree, Pairs} = fixture(),
    Sorted = lists:sort(Pairs),
    [{H1, A1}, {H2, A2} | _] = Sorted,
    %% Chunk of two with boundary proof of the second.
    Proof = eth_trie:prove(Tree, H2),
    {ok, Got, true} = eth_snap:verify_account_range(
                        [H1, H2], [A1, A2], Proof, Root),
    ?assertEqual(lists:sort([{H1, A1}, {H2, A2}]), Got),
    %% Tampered value: boundary no longer binds (reported incomplete).
    BadA2 = <<0, A2/binary>>,
    {ok, _, false} = eth_snap:verify_account_range(
                       [H1, H2], [A1, BadA2], Proof, Root),
    %% Wrong root: boundary unverifiable (reported incomplete, not ok).
    {ok, _, false} = eth_snap:verify_account_range(
                       [H1, H2], [A1, A2], Proof, <<0:256>>),
    %% Reordered keys are rejected outright.
    ?assertMatch({error, _}, eth_snap:verify_account_range(
                               [H2, H1], [A2, A1], Proof, Root)).

storage_verify_test() ->
    %% Storage trie over 3 slots, verified the same way.
    Slots = [{eth_keccak:hash(<<S:256>>), eth_rlp:encode(S * 7)} ||
                S <- [1, 2, 3]],
    Tree = eth_trie:build(Slots),
    Root = eth_trie:root(Slots),
    Sorted = lists:sort(Slots),
    {Hs, Vs} = lists:unzip(Sorted),
    {LastH, _} = lists:last(Sorted),
    Proof = eth_trie:prove(Tree, LastH),
    {ok, Got, _} = eth_snap:verify_storage_range(Hs, Vs, Proof, Root),
    ?assertEqual(Sorted, Got).

codec_test() ->
    Root = crypto:strong_rand_bytes(32),
    Origin = crypto:strong_rand_bytes(32),
    Req = eth_snap:encode_account_req(Root, Origin, 100),
    {ok, Root, Origin, 100} =
        eth_snap:decode_account_req_bin(eth_rlp:encode(Req)),
    Acct = crypto:strong_rand_bytes(32),
    SReq = eth_snap:encode_storage_req(Root, Acct, Origin, 50),
    {ok, Root, Acct, Origin, 50} =
        eth_snap:decode_storage_req_bin(eth_rlp:encode(SReq)),
    BReq = eth_snap:encode_bytecodes_req([Root]),
    {ok, [Root]} = eth_snap:decode_bytecodes_bin(eth_rlp:encode(BReq)),
    ?assertEqual({error, bad_account_req},
                 eth_snap:decode_account_req_bin(<<1, 2, 3>>)).

negotiate_test() ->
    Caps = eth_eth:negotiate_caps(eth_eth:caps(), [{<<"eth">>, 68}]),
    ?assertMatch(#{eth := #{base := 16}}, Caps),
    ?assertNot(maps:is_key(snap, Caps)),
    Caps2 = eth_eth:negotiate_caps(eth_eth:caps(),
                                   [{<<"eth">>, 68}, {<<"snap">>, 1}]),
    ?assertMatch(#{eth := #{base := 16}, snap := #{base := 33}}, Caps2).
