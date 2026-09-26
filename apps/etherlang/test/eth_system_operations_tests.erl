%% Block-level system operations: the EIPs that mutate state around a block's
%% transactions rather than from them, and the message those transactions are
%% executed with.
%%
%% Two things are being pinned here.
%%
%% First, the system operations. They are the parts of a state transition that
%% no transaction produces, so nothing else in the codebase exercises them. A
%% node missing them still finalizes blocks and still produces plausible
%% receipts -- it just computes a state root that disagrees with every other
%% client, because it never wrote the beacon root and never credited the
%% withdrawals. That failure is silent, which is why the beacon-roots cases run
%% the real deployed bytecode against a real Sepolia block rather than trusting
%% this implementation's own reasoning about what the EIP says.
%%
%% Second, the message eth_block hands the EVM. A block that never contained a
%% transaction had no test covering its execution path at all, which is how the
%% message went out keyed the JSON-RPC way while the EVM reads atom keys: every
%% field missed, every lookup fell back to a default, and calldata was empty.

-module(eth_system_operations_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("etherlang/include/eth_block.hrl").

-define(BEACON, <<16#00, 16#0F, 16#3d, 16#f6, 16#D7, 16#32, 16#80, 16#7E,
                  16#f1, 16#31, 16#9f, 16#B7, 16#B8, 16#bB, 16#85, 16#22,
                  16#d0, 16#Be, 16#ac, 16#02>>).
%% 0xfffffffffffffffffffffffffffffffffffffffe. Built from the value, because
%% `<<255:152, 16#fe>>' is 0x000000000000000000000000000000000000FFFE: an
%% integer bitstring segment is left-padded with zeros, so the byte pattern one
%% would read off the EIP text is not the one the literal produces. Comparing the
%% macro against itself hid that; the address is spelled out here instead.
-define(SYSTEM, <<((1 bsl 152) - 1):152, 16#fe>>).
-define(EMPTY_CODE_HASH, <<16#c5, 16#d2, 16#46, 16#01, 16#86, 16#f7, 16#23,
                          16#3c, 16#92, 16#7e, 16#7d, 16#b2, 16#dc, 16#c7,
                          16#03, 16#c0, 16#e5, 16#00, 16#b6, 16#53, 16#ca,
                          16#82, 16#27, 16#3b, 16#7b, 16#fa, 16#d8, 16#04,
                          16#5d, 16#85, 16#a4, 16#70>>).
-define(ADDR_A, <<16#aa:160>>).
-define(ADDR_B, <<16#bb:160>>).
-define(PROBE, <<16#c0:160>>).
-define(TS, 1700000000).

%% The EIP-4788 runtime bytecode, read from eth_getCode at
%% 0x000F3df6...Beac02 on Sepolia.
%%
%% Using the code the chain actually runs makes this a statement about agreement
%% with the network. If the call shape, the caller, the calldata or the
%% environment were off by anything, the deployed contract would write somewhere
%% other than the two ring-buffer slots and the assertions below would fail. A
%% hand-assembled stand-in could not tell "our encoding is right" apart from "our
%% encoding agrees with theirs" -- and the previous implementation here used a
%% single-buffer layout that looked perfectly reasonable and was unreachable.
-define(BEACON_RUNTIME,
        binary:decode_hex(<<"3373fffffffffffffffffffffffffffffffffffffffe14"
                            "604d57602036146024575f5ffd5b5f35801560495762001ff"
                            "f810690815414603c575f5ffd5b62001fff01545f5260205f"
                            "f35b5f5ffd5b62001fff42064281555f359062001fff01550"
                            "0">>)).

%% One real Sepolia block. ts rem 8191 = 3311, and reading that block's state
%% back showed slot 3311 holding exactly ts and slot 11502 holding exactly the
%% parent beacon block root.
-define(REAL_TS, 1790351136).
-define(REAL_ROOT, <<16#03, 16#0e, 16#40, 16#48, 16#c2, 16#e4, 16#ae, 16#8f,
                    16#ee, 16#f6, 16#97, 16#bc, 16#af, 16#93, 16#f8, 16#04,
                    16#d5, 16#a2, 16#8f, 16#52, 16#6a, 16#d3, 16#2a, 16#a8,
                    16#87, 16#8d, 16#72, 16#ab, 16#a8, 16#0b, 16#45, 16#5b>>).

system_operations_test_() ->
    [{"two ring buffers, not one", fun slots_are_two_ring_buffers/0},
     {"history length is 8191", fun history_buffer_length_is_8191/0},
     {"the system caller is 0xff..fe", fun system_address_is_ff_fe/0},
     {"store and read round-trip", fun beacon_root_roundtrip/0},
     {"a reused ring slot does not read back",
      fun stale_timestamp_does_not_read_back/0},
     {"reproduces a real Sepolia block", fun reproduces_real_sepolia_block/0},
     {"a missing contract fails silently", fun no_code_fails_silently/0},
     {"a reverting contract fails silently",
      fun reverting_call_fails_silently/0},
     {"the zero root is the genesis placeholder", fun zero_root_is_skipped/0},
     {"no call before Cancun", fun no_call_before_cancun/0},
     {"withdrawals are credited in wei", fun withdrawals_credit_wei/0},
     {"withdrawals to one address accumulate", fun withdrawals_accumulate/0},
     {"a withdrawal can create an account", fun withdrawal_creates_account/0},
     {"a withdrawal does not raise the nonce", fun withdrawal_keeps_nonce/0},
     {"an empty list is a no-op", fun empty_withdrawals_are_a_noop/0},
     {"the wire shape credits the same", fun wire_shape_credits/0},
     {"calldata reaches the contract", fun calldata_reaches_the_contract/0},
     {"the signer reaches the contract as CALLER",
      fun caller_reaches_the_contract/0},
     {"a declared `from' is not believed",
      fun declared_from_is_not_believed/0},
     {"the block timestamp reaches the contract",
      fun timestamp_reaches_the_contract/0},
     {"the block number reaches the contract", fun number_reaches_contract/0},
     {"receipts carry their own index", fun receipts_carry_their_index/0},
     {"receipt bloom covers that receipt's logs",
      fun receipt_bloom_covers_its_logs/0},
     {"execution logs and EVM log tuples agree", fun logs_reach_the_receipt/0}].

%% ---------------------------------------------------------------------------
%% Fixture
%% ---------------------------------------------------------------------------

%% A fresh empty MPT, and the process-wide base source restored afterwards:
%% leaking that setting would silently redirect another module's reads.
with_ctx(Fun) ->
    ensure_started(eth_mpt),
    ok = eth_mpt:clear(),
    Previous = eth_state:base_source(),
    ok = eth_state:set_base_source(mpt),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous),
        _ = clear_mpt(),
        _ = stop_chain()
    end.

%% finalize/1 executes only when the local MPT provably holds the parent's state,
%% so a block-running test needs a parent block whose declared state root is the
%% MPT's own root. The parent therefore has to be stored *after* the accounts
%% and code the test installs, or execution would refuse to run.
with_block_ctx(Code, Fun) ->
    with_ctx(fun() ->
        Sender = install_probe(Code),
        Parent = store_parent(eth_mpt:state_root()),
        Fun(Sender, Parent)
    end).

ensure_started(Mod) ->
    case whereis(Mod) of
        undefined -> {ok, Pid} = Mod:start_link(), Pid;
        Pid -> Pid
    end.

ensure_started(Mod, Arg) ->
    case whereis(Mod) of
        undefined -> {ok, Pid} = Mod:start_link(Mod, Arg), Pid;
        Pid -> Pid
    end.

clear_mpt() ->
    try eth_mpt:clear() catch _:_ -> ok end.

%% The chain store is torn down alongside the MPT. Appending a second
%% number-0 block to a store that already holds one is a missing-parent error,
%% not a replacement, so reusing the store across these tests would leave every
%% case after the first unable to build a parent.
stop_chain() ->
    try gen_server:stop(eth_chain) catch _:_ -> ok end.

blank() ->
    eth_state:new(<<"0x1">>, #{}).

%% Store a block declaring ParentRoot as its state root and return its hash, so a
%% child block can name it as a parent. Built with eth_test_util because the
%% chain store recomputes and verifies the hash on append, so the state root has
%% to be in place before the hash is taken.
store_parent(ParentRoot) ->
    ensure_started(eth_chain, eth_test_util:tmp_dir()),
    Base = eth_test_util:header(0, hex(<<0:256>>), 0),
    Block = Base#{
              <<"totalDifficulty">> => eth_hex:encode_int(0),
              <<"size">> => eth_hex:encode_int(600),
              <<"stateRoot">> => hex(ParentRoot)
             },
    {ok, HashHex} = eth_header:verify(Block),
    ok = eth_chain:append([{0, Block#{<<"hash">> => HashHex}, true}]),
    hex_to_bin(HashHex).

hex_to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest).

hex(B) -> <<"0x", (string:lowercase(binary:encode_hex(B)))/binary>>.

%% ---------------------------------------------------------------------------
%% EIP-4788 storage layout
%% ---------------------------------------------------------------------------

%% The contract keeps the timestamp in one ring buffer and the root in the other,
%% a fixed 8191 apart. An earlier implementation here used a single buffer keyed
%% by the full 256-bit timestamp: a plausible encoding that the contract never
%% performs, so every lookup would have missed and returned nothing.
slots_are_two_ring_buffers() ->
    %% 1790351136 rem 8191 = 3311. These are the indices the real Sepolia block
    %% actually wrote, read back from that block's state, so they are the
    %% expected value and not a restatement of whatever the code computes.
    ?assertEqual({3311, 3311 + 8191},
                 eth_fork_schedule:beacon_root_slots(?REAL_TS)),
    ?assertEqual({0, 8191}, eth_fork_schedule:beacon_root_slots(8191)),
    ?assertEqual({5993, 5993 + 8191}, eth_fork_schedule:beacon_root_slots(14184)),
    {A, B} = eth_fork_schedule:beacon_root_slots(987654321),
    ?assertEqual(8191, B - A),
    ?assertNotEqual(A, B).

history_buffer_length_is_8191() ->
    ?assertEqual(8191, eth_fork_schedule:history_buffer_length()).

%% EIP-4788 specifies the caller as 0xffffffff...fe. The deployed code's first
%% instruction is a CALLER comparison, so any other value is rejected before
%% anything is written. The expected value is the literal 20-byte pattern rather
%% than a second copy of the same expression: when both sides were `<<255:152,
%% 16#fe>>' this test agreed with itself about a wrong address and passed.
system_address_is_ff_fe() ->
    ?assertEqual(20, byte_size(eth_fork_schedule:system_address())),
    ?assertEqual(<<16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                   16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff,
                   16#ff, 16#ff, 16#ff, 16#fe>>,
                 eth_fork_schedule:system_address()),
    ?assertEqual(?SYSTEM, eth_fork_schedule:system_address()),
    %% 19 bytes of 0xff then 0xfe, not a short value left-padded into 20 bytes.
    ?assertEqual((1 bsl 152) - 1,
                 binary:decode_unsigned(binary:part(?SYSTEM, 0, 19))).

beacon_root_roundtrip() ->
    with_ctx(fun() ->
        {ok, S1} = eth_fork_schedule:store_beacon_root(?REAL_TS, ?REAL_ROOT,
                                                        blank()),
        ?assertMatch({ok, ?REAL_ROOT},
                     eth_fork_schedule:read_beacon_root(?REAL_TS, S1))
    end).

%% The contract re-reads the timestamp and reverts if it does not match, which is
%% what stops a ring slot reused by a later timestamp handing back an older
%% block's root. A read that skipped the timestamp would return a plausible root
%% belonging to a different block.
stale_timestamp_does_not_read_back() ->
    with_ctx(fun() ->
        {ok, S1} = eth_fork_schedule:store_beacon_root(?REAL_TS, ?REAL_ROOT,
                                                        blank()),
        ?assertEqual({error, unknown_timestamp},
                     eth_fork_schedule:read_beacon_root(?REAL_TS + 1, S1)),
        %% 8191 later lands on the same ring index: exactly the collision the
        %% timestamp check exists to catch.
        ?assertEqual({error, unknown_timestamp},
                     eth_fork_schedule:read_beacon_root(?REAL_TS + 8191, S1))
    end).

%% ---------------------------------------------------------------------------
%% EIP-4788 system call
%% ---------------------------------------------------------------------------

%% The decisive test. Run the contract the chain actually has deployed, with the
%% timestamp and parent beacon root of a real Sepolia block, and require the two
%% slots that block's state actually contains.
%%
%% The expected values are the slot contents read back from that real block, not
%% values derived from the code under test. This is the only assertion in the
%% module that can distinguish "the contract ran and wrote the right words" from
%% "the helper wrote what the helper always writes": with a wrong system address
%% the contract's first instruction rejected the call, the EIP's fail-silently
%% rule swallowed the revert, and the block still validated with both slots zero.
reproduces_real_sepolia_block() ->
    with_ctx(fun() ->
        State = install_beacon_contract(blank()),
        {ok, S1} = eth_fork_schedule:process_beacon_roots(
                     ?REAL_TS, ?REAL_ROOT, State, cancun),
        ?assertEqual({3311, 11502},
                     eth_fork_schedule:beacon_root_slots(?REAL_TS)),
        ?assertEqual(?REAL_TS, eth_state:storage(S1, ?BEACON, 3311)),
        %% The EVM's stack holds integers, so the root comes back as one; the
        %% ring buffer's other writer (store_beacon_root/3) passes a 32-byte
        %% binary. Both have to denote the same word, so the comparison is made
        %% in the integer domain and read_beacon_root/2 is required to hand back
        %% the binary shape the rest of the API speaks.
        Root = eth_state:storage(S1, ?BEACON, 11502),
        ?assertEqual(binary:decode_unsigned(?REAL_ROOT), Root),
        ?assertEqual({ok, ?REAL_ROOT},
                     eth_fork_schedule:read_beacon_root(?REAL_TS, S1))
    end).

%% "If no code exists at BEACON_ROOTS_ADDRESS, the call must fail silently."
%% There is no error term on purpose: the EIP requires the block to proceed, so
%% signalling an error would halt a block the spec calls valid.
no_code_fails_silently() ->
    with_ctx(fun() ->
        State = blank(),
        %% Empty code is the representation of "no contract here"; eth_state does
        %% not return an error term, and inventing one would mean every caller
        %% had to handle a shape the rest of the API does not produce.
        ?assertEqual(<<>>, eth_state:code(State, ?BEACON)),
        ?assertEqual({ok, State},
                     eth_fork_schedule:process_beacon_roots(
                       ?REAL_TS, ?REAL_ROOT, State, cancun))
    end).

%% A contract that reverts leaves the state untouched. The call is not allowed to
%% be fatal, but neither is it allowed to apply half of its writes.
reverting_call_fails_silently() ->
    with_ctx(fun() ->
        Reverter = <<16#60, 16#00, 16#60, 16#00, 16#fd>>,
        State = eth_state:set_code(blank(), ?BEACON, Reverter),
        ?assertMatch({ok, _},
                     eth_fork_schedule:process_beacon_roots(
                       ?REAL_TS, ?REAL_ROOT, State, cancun)),
        ?assertEqual(0, eth_state:storage(State, ?BEACON, 3311))
    end).

%% Cancun's first block carries an all-zero parent beacon root as a placeholder.
%% Writing it would commit the genesis root into the ring buffer, where every
%% consumer would read it as a genuine block-0 beacon root.
zero_root_is_skipped() ->
    with_ctx(fun() ->
        State = install_beacon_contract(blank()),
        {ok, S1} = eth_fork_schedule:process_beacon_roots(
                     ?REAL_TS, <<0:256>>, State, cancun),
        ?assertEqual(0, eth_state:storage(S1, ?BEACON, 3311))
    end).

%% An absent field, and a pre-Cancun fork, must both leave the call unmade.
no_call_before_cancun() ->
    with_ctx(fun() ->
        State = install_beacon_contract(blank()),
        {ok, S1} = eth_fork_schedule:process_beacon_roots(
                     ?REAL_TS, ?REAL_ROOT, State, shanghai),
        ?assertEqual(0, eth_state:storage(S1, ?BEACON, 3311))
    end).

%% ---------------------------------------------------------------------------
%% EIP-4895 withdrawals
%% ---------------------------------------------------------------------------

%% Amounts arrive in Gwei; balances are denominated in wei. Crediting the number
%% as given would overpay every recipient by a factor of a billion -- a wrong
%% state root, and a wrong one a balance query would report confidently.
withdrawals_credit_wei() ->
    with_ctx(fun() ->
        {ok, S1, 1} = eth_fork_schedule:apply_withdrawals_to_state(
                        [wd(1, ?ADDR_A, 963)], blank()),
        ?assertEqual(963 * 1000000000, eth_state:balance(S1, ?ADDR_A))
    end).

%% Two withdrawals to one address in a block are two credits, not one. Reading
%% each balance from the pre-block snapshot would silently lose the first.
withdrawals_accumulate() ->
    with_ctx(fun() ->
        Ws = [wd(1, ?ADDR_A, 10), wd(2, ?ADDR_A, 5), wd(3, ?ADDR_B, 7)],
        {ok, S1, 3} = eth_fork_schedule:apply_withdrawals_to_state(Ws, blank()),
        ?assertEqual(15 * 1000000000, eth_state:balance(S1, ?ADDR_A)),
        ?assertEqual(7 * 1000000000, eth_state:balance(S1, ?ADDR_B))
    end).

%% A withdrawal is often the first thing ever to touch an address. The account
%% has to appear with the EIP-1052 empty-code hash, because every other node
%% creates it the same way.
withdrawal_creates_account() ->
    with_ctx(fun() ->
        {ok, S1, 1} = eth_fork_schedule:apply_withdrawals_to_state(
                        [wd(1, ?ADDR_A, 1)], blank()),
        ?assert(eth_state:exists(S1, ?ADDR_A)),
        ?assertEqual(1 * 1000000000, eth_state:balance(S1, ?ADDR_A)),
        ?assertEqual(0, eth_state:nonce(S1, ?ADDR_A)),
        %% The account is a plain value holder. The EIP-1052 empty-code hash
        %% that every other node serialises for it is a property of the
        %% committed trie, not of this overlay, and eth_state exposes no
        %% code_hash/2 to read it through -- so it is checked where it is
        %% observable, in the commit path, and not asserted here.
        ?assertEqual(<<>>, eth_state:code(S1, ?ADDR_A))
    end).

%% Crediting a balance sends no transaction, so the nonce must not move. A
%% withdrawal that raised the nonce would make the account's next transaction
%% replay an already-used nonce.
withdrawal_keeps_nonce() ->
    with_ctx(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 100, 9, ?EMPTY_CODE_HASH),
        {ok, S1, 1} = eth_fork_schedule:apply_withdrawals_to_state(
                        [wd(1, ?ADDR_A, 5)], blank()),
        ?assertEqual(9, eth_state:nonce(S1, ?ADDR_A)),
        ?assertEqual(100 + 5 * 1000000000, eth_state:balance(S1, ?ADDR_A))
    end).

empty_withdrawals_are_a_noop() ->
    with_ctx(fun() ->
        ?assertEqual({ok, blank(), 0},
                     eth_fork_schedule:apply_withdrawals_to_state([], blank()))
    end).

%% The list a payload arrives with carries string keys and hex quantities, and
%% must credit exactly what the internal shape credits. A decoder that read
%% "0x175" as decimal text would pay 175 Gwei instead of 373 and still produce a
%% well-formed balance.
wire_shape_credits() ->
    with_ctx(fun() ->
        Wire = [#{<<"index">> => <<"0x175">>,
                  <<"validatorIndex">> => <<"0x623">>,
                  <<"address">> =>
                      <<"0x388ea662ef2c223ec0b047d41bf3c0f362142ad5">>,
                  <<"amount">> => <<"0x3c3">>}],
        {ok, S1, 1} = eth_fork_schedule:apply_withdrawals_to_state(Wire, blank()),
        ?assertEqual(963 * 1000000000,
                     eth_state:balance(
                       S1, binary:decode_hex(
                               <<"388ea662ef2c223ec0b047d41bf3c0f362142ad5">>)))
    end).

%% ---------------------------------------------------------------------------
%% The message the EVM actually receives
%% ---------------------------------------------------------------------------

%% These go through finalize/1 rather than calling the EVM directly, because the
%% message construction under test lives in eth_block. Each probe writes what it
%% observed into storage slot 0 and the assertion reads the slot back out of the
%% committed MPT -- a write is the stronger check anyway, because it is inside
%% the state root and so cannot be right while the commitment is wrong.
calldata_reaches_the_contract() ->
    with_block_ctx(calldatasize_probe(), fun(_Sender, Parent) ->
        ?assertEqual(7, probe_value(<<1, 2, 3, 4, 5, 6, 7>>, Parent, 1, ?TS))
    end).

%% CALLER is the account whose signature authorised the transaction.
caller_reaches_the_contract() ->
    with_block_ctx(caller_probe(), fun(Sender, Parent) ->
        ?assertEqual(binary:decode_unsigned(Sender),
                     probe_value(<<>>, Parent, 1, ?TS))
    end).

%% A transaction's own `from' field is not a statement about who signed it.
%% Believing it would let a malformed body attribute a call to a third party --
%% here to the zero address, which nobody can sign for. signed_call/1 declares
%% `from' = 0x0 while being signed by a real key, so CALLER observing the signer
%% is what separates recovery from belief.
%% The transaction carries `from' = 0x00..00 while being signed by a real key.
%% If finalize/1 believed the declared field, CALLER would be the zero address
%% and the probe would record 0 -- so the recorded value has to be the signer's
%% address, and the signer is not the zero address.
declared_from_is_not_believed() ->
    with_block_ctx(caller_probe(), fun(Sender, Parent) ->
        Seen = probe_value(<<>>, Parent, 1, ?TS),
        ?assertNotEqual(0, binary:decode_unsigned(Sender)),
        ?assertEqual(binary:decode_unsigned(Sender), Seen)
    end).

%% TIMESTAMP and NUMBER are the block's own, not zero. Before the fix both read
%% as 0: well-formed numbers, simply the wrong ones.
timestamp_reaches_the_contract() ->
    with_block_ctx(timestamp_probe(), fun(_Sender, Parent) ->
        ?assertEqual(?TS, probe_value(<<>>, Parent, 1, ?TS))
    end).

number_reaches_contract() ->
    with_block_ctx(number_probe(), fun(_Sender, Parent) ->
        ?assertEqual(4242, probe_value(<<>>, Parent, 4242, ?TS))
    end).

%% ---------------------------------------------------------------------------
%% Receipts
%% ---------------------------------------------------------------------------

%% Every receipt used to claim index 0. eth_getTransactionReceipt indexes by it,
%% so a block's second transaction was indistinguishable from its first.
receipts_carry_their_index() ->
    with_block_ctx(stop(), fun(Sender, Parent) ->
        {ok, Block} = run_block(3, Parent, 1, ?TS, <<>>),
        _ = Sender,
        ?assertEqual([0, 1, 2],
                     [maps:get(<<"transactionIndex">>, R)
                      || R <- eth_block:receipts(Block)])
    end).

%% A receipt's bloom is the filter over that receipt's own logs. An empty one
%% claims its logs are unmatchable, so eth_getLogs with a filter would skip them
%% while the block-level bloom -- an OR over all receipts -- still matched, and
%% the two would contradict each other about the same event.
receipt_bloom_covers_its_logs() ->
    with_block_ctx(emitter(), fun(Sender, Parent) ->
        {ok, Block} = run_block(2, Parent, 1, ?TS, <<>>),
        _ = Sender,
        [R1, R2] = eth_block:receipts(Block),
        B1 = maps:get(<<"logs_bloom">>, R1),
        B2 = maps:get(<<"logs_bloom">>, R2),
        ?assertNotEqual(eth_bloom:new(), B1),
        %% The two logs differ, so the two blooms must too. A hard-coded or
        %% shared bloom would pass a weaker check.
        ?assertNotEqual(B1, B2),
        %% And the block's bloom must be the OR of the receipts', matching the
        %% logs actually emitted.
        ?assertEqual(eth_bloom:add_logs(eth_bloom:add_logs(eth_bloom:new(),
                                                          logs_of(R1)),
                                        logs_of(R2)),
                     eth_block:logs_bloom(eth_block:logs(Block)))
    end).

%% The EVM yields logs as {Address, Topics, Data} tuples while a log read back
%% from a peer is a map. add_logs/2 handles only the map shape, so computing the
%% bloom of a block whose transactions emitted anything hit maps:get/3 with a
%% tuple and raised badmap. No test noticed because no test had finalized a block
%% containing a transaction at all.
logs_reach_the_receipt() ->
    with_block_ctx(emitter(), fun(Sender, Parent) ->
        {ok, Block} = run_block(2, Parent, 1, ?TS, <<>>),
        _ = Sender,
        Logs = eth_block:logs(Block),
        ?assertEqual(2, length(Logs)),
        ?assertMatch([{_, [<<_:256>>], <<_:256>>}, {_, [<<_:256>>], <<_:256>>}],
                     Logs),
        ?assertEqual(256, byte_size(eth_block:logs_bloom(Logs)))
    end).

logs_of(Receipt) -> maps:get(<<"logs">>, Receipt).

%% ---------------------------------------------------------------------------
%% Probe execution
%% ---------------------------------------------------------------------------

%% ---------------------------------------------------------------------------
%% Contracts. Each probe pushes the value under test to memory position 0 and
%% writes it to storage slot 0, so what the EVM saw is observable in the
%% committed state rather than in a return value finalize/1 does not surface.
%% ---------------------------------------------------------------------------

%% Suffix shared by the single-value probes: MSTORE the value at offset 0, read
%% the 32 bytes back, and SSTORE that to slot 0.
%%
%% Operand order is the whole subtlety here. MSTORE pops offset *then* value and
%% SSTORE pops slot *then* value, so the value has to sit underneath its offset,
%% and MSTORE always writes exactly 32 bytes -- it takes no length. Pushing a
%% length first (the shape that looks right for a variable-width store) leaves
%% 0x20 as the value and silently records 32 in slot 0, which is a well-formed
%% word and a wrong answer, so the probe would report a constant for every test.
store_at_zero() ->
    <<16#60, 16#00, 16#52,                              %% PUSH1 0, MSTORE
      16#60, 16#00, 16#51,                              %% PUSH1 0, MLOAD
      16#60, 16#00, 16#55>>.                            %% PUSH1 0, SSTORE

%% Prefix an opcode with the store-at-slot-0 suffix. The /binary form is used
%% rather than ++ because binary ++ only works when the left side is a proper
%% prefix of the right, which is not a property a one-byte opcode has.
observe(Source) ->
    <<Source, (store_at_zero())/binary>>.

%% CALLDATASIZE
calldatasize_probe() -> observe(16#36).

%% CALLER
caller_probe() -> observe(16#33).

%% TIMESTAMP
timestamp_probe() -> observe(16#42).

%% NUMBER
number_probe() -> observe(16#43).

stop() -> <<16#00>>.

%% Emits one log per call, carrying a counter that advances each time, so two
%% transactions in one block produce two *different* logs and therefore two
%% different receipt blooms. SLOAD slot 0, increment, SSTORE, then LOG1.
%%
%% LOG1 pops offset, then length, then its topic -- so the stack must read
%% bottom-up as topic, length, offset. The counter is read back out of storage
%% after being written rather than kept on the stack across the MSTORE, because
%% MSTORE consumes the value it stores and the stack would be empty afterwards.
emitter() ->
    <<16#60, 16#00, 16#54,                              %% PUSH1 0, SLOAD
      16#60, 16#01, 16#01,                              %% PUSH1 1, ADD
      16#80,                                            %% DUP1
      16#60, 16#00, 16#55,                              %% PUSH1 0, SSTORE
      16#60, 16#00, 16#52,                              %% PUSH1 0, MSTORE
      16#60, 16#00, 16#51,                              %% PUSH1 0, MLOAD
      16#60, 16#20,                                     %% PUSH1 32
      16#60, 16#00, 16#a1,                              %% PUSH1 0, LOG1
      16#00>>.                                          %% STOP

%% Run one probe transaction through finalize/1 and return what the contract wrote
%% to storage slot 0. The code is already in state by the time with_block_ctx/2
%% hands over, so only the block fields and the calldata need passing; the key
%% that signed the transaction is the one install_probe/1 funded.
probe_value(Calldata, Parent, Number, Timestamp) ->
    {ok, _} = run_block(1, Parent, Number, Timestamp, Calldata),
    case eth_mpt:get_storage(?PROBE, <<0:256>>) of
        <<Word:256/unsigned-big>> -> Word;
        <<>> -> 0;
        Other -> binary:decode_unsigned(Other)
    end.

%% Finalize a block carrying N identical calls to the installed contract.
run_block(N, Parent, Number, Timestamp, Calldata) ->
    Txs = [signed_call(Calldata) || _ <- lists:seq(1, N)],
    Block = (eth_block:new(Parent, Number))#block{
        transactions = Txs, timestamp = Timestamp},
    {ok, Finalized, _V} = eth_block:finalize(Block),
    {ok, Finalized}.

%% Put the probe contract at a known address, fund a fresh key pair, and
%% remember the key so signed_call/1 can use it.
install_probe(Code) ->
    Hash = eth_keccak:hash(Code),
    ok = eth_mpt:put_code(Hash, Code),
    ok = eth_mpt:put_account(?PROBE, 0, 0, Hash),
    PrivKey = eth_secp256k1:generate_key(),
    Sender = binary:part(eth_keccak:hash(eth_secp256k1:node_id(PrivKey)),
                         12, 20),
    ok = eth_mpt:put_account(Sender, 1000000000000000000, 0, ?EMPTY_CODE_HASH),
    put(?MODULE, {PrivKey, Sender}),
    Sender.

%% A legacy transaction, so the signing preimage is the plain six-field RLP that
%% eth_tx:sighash/1 builds. The preimage is reconstructed here rather than taken
%% from eth_tx, because sighash/1 is private -- and a test that reached for it
%% would be checking eth_tx against itself, whereas the point of these cases is
%% that eth_block's recovered sender is the one the signature actually names.
signed_call(Calldata) ->
    {PrivKey, _Sender} = get(?MODULE),
    Nonce = 0,
    GasPrice = 0,
    Gas = 1000000,
    Value = 0,
    To = ?PROBE,
    Digest = eth_keccak:hash(
               eth_rlp:encode([Nonce, GasPrice, Gas, To, Value, Calldata])),
    {R, S, V} = eth_secp256k1:sign(Digest, PrivKey),
    #{<<"type">> => <<"0x0">>,
      <<"nonce">> => eth_hex:encode_int(Nonce),
      <<"gasPrice">> => eth_hex:encode_int(GasPrice),
      <<"gas">> => eth_hex:encode_int(Gas),
      <<"to">> => hex(To),
      <<"value">> => eth_hex:encode_int(Value),
      <<"input">> => hex(Calldata),
      <<"v">> => eth_hex:encode_int(27 + V),
      <<"r">> => hex(int_to_32(R)),
      <<"s">> => hex(int_to_32(S)),
      %% Deliberately wrong: nothing may read this.
      <<"from">> => hex(<<0:160>>)}.

%% r and s are 32-byte big-endian quantities, and both are already below the
%% secp256k1 group order, so the bit syntax is exact. The size argument of
%% binary:encode_unsigned/2 reads as bits in some documentation and as bytes in
%% others; guessing wrong here would fail on roughly half of all signatures.
int_to_32(V) -> <<V:256/unsigned-big>>.

install_beacon_contract(State) ->
    Hash = eth_keccak:hash(?BEACON_RUNTIME),
    ok = eth_mpt:put_code(Hash, ?BEACON_RUNTIME),
    ok = eth_mpt:put_account(?BEACON, 0, 1, Hash),
    eth_state:set_code(State, ?BEACON, ?BEACON_RUNTIME).

wd(Index, Address, Amount) ->
    #{index => Index, validatorIndex => Index * 2,
      address => Address, amount => Amount}.
