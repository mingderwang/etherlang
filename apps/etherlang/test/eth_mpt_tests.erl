-module(eth_mpt_tests).

-include_lib("eunit/include/eunit.hrl").

-define(EMPTY_CODE_HASH, <<16#c5, 16#d2, 16#46, 16#01, 16#86, 16#f7, 16#23,
                          16#3c, 16#92, 16#7e, 16#7d, 16#b2, 16#dc, 16#c7,
                          16#03, 16#c0, 16#e5, 16#00, 16#b6, 16#53, 16#ca,
                          16#82, 16#27, 16#3b, 16#7b, 16#fa, 16#d8, 16#04,
                          16#5d, 16#85, 16#a4, 16#70>>).

with_mpt(Fun) ->
    {ok, _} = eth_mpt:start_link(),
    ok = eth_mpt:clear(),
    try Fun()
    after
        ok = eth_mpt:clear()
    end.

%% ---------------------------------------------------------------------------
%% The state root must actually track state.
%% ---------------------------------------------------------------------------

%% The empty trie root is keccak(RLP("")), the canonical empty state root.
empty_state_root_test() ->
    with_mpt(fun() ->
        ?assertEqual(eth_trie:root([]), eth_mpt:state_root())
    end).

%% This is the bug that made state-root verification meaningless: the root was
%% cached at init and never recomputed, so it stayed at the empty root no matter
%% what was written. Any account write must move it.
state_root_tracks_accounts_test() ->
    with_mpt(fun() ->
        Empty = eth_mpt:state_root(),
        A = <<1:160>>,
        ok = eth_mpt:put_account(A, 100, 0, ?EMPTY_CODE_HASH),
        R1 = eth_mpt:state_root(),
        ?assertNotEqual(Empty, R1),
        %% A different balance is a different state.
        ok = eth_mpt:put_account(A, 101, 0, ?EMPTY_CODE_HASH),
        R2 = eth_mpt:state_root(),
        ?assertNotEqual(R1, R2),
        %% So is a different nonce.
        ok = eth_mpt:put_account(A, 101, 1, ?EMPTY_CODE_HASH),
        R3 = eth_mpt:state_root(),
        ?assertNotEqual(R2, R3),
        %% So is a different address.
        ok = eth_mpt:put_account(<<2:160>>, 100, 0, ?EMPTY_CODE_HASH),
        R4 = eth_mpt:state_root(),
        ?assertNotEqual(R3, R4),
        %% Removing the last account returns to the empty root.
        ok = eth_mpt:delete_account(<<1:160>>),
        ok = eth_mpt:delete_account(<<2:160>>),
        ?assertEqual(Empty, eth_mpt:state_root())
    end).

%% The state root is a pure function of the account set, independent of write
%% order, which is what makes it a commitment rather than a log.
state_root_is_order_independent_test() ->
    with_mpt(fun() ->
        A = <<10:160>>,
        B = <<11:160>>,
        C = <<12:160>>,
        ok = eth_mpt:put_account(A, 1, 0, ?EMPTY_CODE_HASH),
        ok = eth_mpt:put_account(B, 2, 0, ?EMPTY_CODE_HASH),
        ok = eth_mpt:put_account(C, 3, 0, ?EMPTY_CODE_HASH),
        Forward = eth_mpt:state_root(),
        ok = eth_mpt:clear(),
        ok = eth_mpt:put_account(C, 3, 0, ?EMPTY_CODE_HASH),
        ok = eth_mpt:put_account(B, 2, 0, ?EMPTY_CODE_HASH),
        ok = eth_mpt:put_account(A, 1, 0, ?EMPTY_CODE_HASH),
        ?assertEqual(Forward, eth_mpt:state_root())
    end).

%% Pin the exact byte layout of an account leaf so a refactor cannot silently
%% change what is committed. For a single account the trie has one leaf:
%%   root = keccak(RLP([hex_prefix(keccak(Addr)), RLP([nonce, balance,
%%                                                   storageRoot, codeHash])]))
%% This is spelled out here independently of eth_mpt's implementation.
state_root_matches_spec_layout_test() ->
    with_mpt(fun() ->
        Addr = <<16#aa, 16#bb, 16#cc, 16#dd, 16#11, 16#22, 16#33, 16#44,
                 16#55, 16#66, 16#77, 16#88, 16#99, 16#aa, 16#bb, 16#cc,
                 16#dd, 16#ee, 16#ff, 16#00>>,
        Balance = 1000000000000000000,
        Nonce = 7,
        ok = eth_mpt:put_account(Addr, Balance, Nonce, ?EMPTY_CODE_HASH),

        StorageRoot = eth_trie:root([]),
        Key = eth_keccak:hash(Addr),
        Nibbles = [N || <<N:4>> <= Key],
        AccountRlp = eth_rlp:encode([Nonce, Balance, StorageRoot, ?EMPTY_CODE_HASH]),
        Expected = eth_keccak:hash(
            eth_rlp:encode([hex_prefix(Nibbles), AccountRlp])),
        ?assertEqual(Expected, eth_mpt:state_root())
    end).

%% ---------------------------------------------------------------------------
%% Storage
%% ---------------------------------------------------------------------------

%% A storage write must change the account's storage root, and therefore the
%% state root, without disturbing the account's balance or nonce.
storage_write_changes_state_root_test() ->
    with_mpt(fun() ->
        A = <<3:160>>,
        Slot = <<16#01:256>>,
        ok = eth_mpt:put_account(A, 500, 2, ?EMPTY_CODE_HASH),
        Before = eth_mpt:state_root(),
        ok = eth_mpt:put_storage(A, Slot, 42),
        After = eth_mpt:state_root(),
        ?assertNotEqual(Before, After),
        %% get_storage/2 returns the raw stored bytes (or undefined); the RLP
        %% minimal-encoding step already stripped the leading zeros.
        ?assertEqual(<<42>>, eth_mpt:get_storage(A, Slot)),
        %% The account itself is untouched: a storage write must not reset the
        %% balance or nonce of the account it belongs to.
        ?assertEqual(#{balance => 500, nonce => 2, codeHash => ?EMPTY_CODE_HASH},
                     eth_mpt:get_account(A)),
        ok = eth_mpt:delete_storage(A, Slot),
        ?assertEqual(Before, eth_mpt:state_root())
    end).

%% Storage values are RLP-encoded with leading zero bytes stripped, so 0, 1 and
%% 256 must be distinguishable and canonical.
storage_value_encoding_test() ->
    with_mpt(fun() ->
        A = <<4:160>>,
        S0 = <<16#00:256>>,
        S1 = <<16#01:256>>,
        S256 = <<16#0100:256>>,
        ok = eth_mpt:put_storage(A, S0, 0),
        ?assertEqual(<<>>, eth_mpt:get_storage(A, S0)),
        ok = eth_mpt:put_storage(A, S1, 1),
        ?assertEqual(<<1>>, eth_mpt:get_storage(A, S1)),
        ok = eth_mpt:put_storage(A, S256, 256),
        ?assertEqual(<<1, 0>>, eth_mpt:get_storage(A, S256))
    end).

%% Writing storage for an unknown address creates a minimal account, because
%% the state trie needs a storage root for every account it holds.
storage_creates_missing_account_test() ->
    with_mpt(fun() ->
        A = <<5:160>>,
        Slot = <<16#07:256>>,
        ?assertEqual(undefined, eth_mpt:get_account(A)),
        ok = eth_mpt:put_storage(A, Slot, 9),
        ?assertEqual(#{balance => 0, nonce => 0, codeHash => ?EMPTY_CODE_HASH},
                     eth_mpt:get_account(A)),
        ?assertEqual(1, eth_mpt:account_count())
    end).

%% Two accounts with the same storage content have the same storage root but
%% different state roots, because the account trie is keyed by address.
storage_roots_are_per_account_test() ->
    with_mpt(fun() ->
        A = <<6:160>>,
        B = <<7:160>>,
        Slot = <<16#09:256>>,
        ok = eth_mpt:put_account(A, 1, 0, ?EMPTY_CODE_HASH),
        RA = eth_mpt:state_root(),
        ok = eth_mpt:put_account(B, 1, 0, ?EMPTY_CODE_HASH),
        RB = eth_mpt:state_root(),
        ok = eth_mpt:put_storage(A, Slot, 1),
        R1 = eth_mpt:state_root(),
        ok = eth_mpt:put_storage(B, Slot, 1),
        R2 = eth_mpt:state_root(),
        ?assertNotEqual(RA, RB),
        ?assertNotEqual(R1, R2)
    end).

%% ---------------------------------------------------------------------------
%% Accounts
%% ---------------------------------------------------------------------------

put_get_account_test() ->
    with_mpt(fun() ->
        A = <<8:160>>,
        ?assertEqual(undefined, eth_mpt:get_account(A)),
        ok = eth_mpt:put_account(A, 12345, 9, ?EMPTY_CODE_HASH),
        ?assertEqual(#{balance => 12345, nonce => 9, codeHash => ?EMPTY_CODE_HASH},
                     eth_mpt:get_account(A)),
        ?assertEqual(1, eth_mpt:account_count()),
        ok = eth_mpt:delete_account(A),
        ?assertEqual(undefined, eth_mpt:get_account(A)),
        ?assertEqual(0, eth_mpt:account_count())
    end).

code_storage_test() ->
    with_mpt(fun() ->
        Code = <<16#60, 16#00, 16#60, 16#00>>,
        H = eth_keccak:hash(Code),
        ?assertEqual(undefined, eth_mpt:get_code(H)),
        ok = eth_mpt:put_code(H, Code),
        ?assertEqual(Code, eth_mpt:get_code(H))
    end).

iter_accounts_test() ->
    with_mpt(fun() ->
        A = <<9:160>>,
        B = <<10:160>>,
        ok = eth_mpt:put_account(A, 1, 0, ?EMPTY_CODE_HASH),
        ok = eth_mpt:put_account(B, 2, 0, ?EMPTY_CODE_HASH),
        Addrs = lists:sort([Addr || {Addr, _} <- eth_mpt:iter_accounts()]),
        ?assertEqual([A, B], Addrs)
    end).

%% ---------------------------------------------------------------------------
%% Hex-prefix encoding, written out here so the account-leaf layout is checked
%% against the specification rather than against eth_trie's own encoder.
%% ---------------------------------------------------------------------------

%% A leaf path of odd length packs as [flag | nibbles]; a leaf path of even
%% length packs as [flag+1, 0 | nibbles]. The leaf flag is 2.
hex_prefix([]) -> <<16#20>>;
hex_prefix([H | T]) ->
    case length(T) rem 2 of
        0 -> pack([3, H | T]);
        1 -> pack([2, 0, H | T])
    end.

pack([]) -> <<>>;
pack([A, B | Rest]) -> <<((A bsl 4) bor B), (pack(Rest))/binary>>.
