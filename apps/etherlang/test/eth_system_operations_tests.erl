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
%% EIP-2935 HISTORY_STORAGE_ADDRESS, 0x0000F90827F1C53a10cb7A02335B175320002935.
-define(HISTORY, <<16#00, 16#00, 16#F9, 16#08, 16#27, 16#F1, 16#C5, 16#3a,
                   16#10, 16#cb, 16#7A, 16#02, 16#33, 16#5B, 16#17, 16#53,
                   16#20, 16#00, 16#29, 16#35>>).
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

%% The EIP-2935 runtime bytecode, read from eth_getCode at
%% 0x0000F908...002935 on Sepolia, for the same reason as ?BEACON_RUNTIME above.
%%
%% This contract is worth running rather than reimplementing, because its write
%% path and its getter disagree in a way that is easy to get wrong by reading the
%% EIP rather than the code. The EIP describes the ring as being keyed by block
%% number, while the EIP-4788 ring right next door in this same file is keyed by
%% timestamp; an implementation that reused the beacon-roots keying here would
%% write to a slot no other client reads, and -- like the earlier 4788 single-ring
%% bug -- would fail silently. Its getter also enforces a 8191-block window and
%% reverts outside it, which no amount of reading the prose would pin down as
%% [number - 8191, number - 1] rather than some other span.
-define(HISTORY_RUNTIME,
        binary:decode_hex(<<"3373fffffffffffffffffffffffffffffffffffffffe14"
                            "60465760203603604257"
                            "5f35600143038111604257611fff81430311604257611fff9"
                            "006545f5260205ff35b5f5ffd5b5f35611fff60014303065500">>)).

%% One real Sepolia block, and the parent hash its post-state records.
%%
%% Block 0xb3ca35 = 11782709. (11782709 - 1) rem 8191 = 4050, and reading that
%% block's state back showed slot 4050 holding exactly this parent hash. The same
%% invariant was re-checked at two further blocks (11782756 and 11782757, ring
%% slots 4097 and 4098), so this is a property of the ring and not a coincidence
%% about one slot.
-define(REAL_NUMBER, 11782709).
-define(REAL_TS_2935, 1790382492).
-define(REAL_PARENT,
        <<16#6a, 16#fa, 16#ff, 16#32, 16#ce, 16#f6, 16#9b, 16#0e,
          16#4b, 16#fd, 16#85, 16#9c, 16#72, 16#80, 16#66, 16#54,
          16#e1, 16#e6, 16#cb, 16#38, 16#9d, 16#9e, 16#fe, 16#1c,
          16#91, 16#a8, 16#ea, 16#69, 16#17, 16#cd, 16#91, 16#ec>>).
-define(REAL_SLOT, 4050).

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
     {"execution logs and EVM log tuples agree", fun logs_reach_the_receipt/0},
     %% EIP-2935 block hash history.
     {"the history ring is keyed by block number",
      fun history_ring_is_keyed_by_block_number/0},
     {"the history window is 8191 blocks", fun history_window_is_8191/0},
     {"reproduces a real Sepolia parent hash",
      fun history_reproduces_real_sepolia_block/0},
     {"the deployed getter serves the parent hash",
      fun history_getter_serves_parent_hash/0},
     {"the getter refuses a block that is not yet in the ring",
      fun history_getter_refuses_future_block/0},
     {"the getter refuses a block past the window",
      fun history_getter_refuses_block_past_window/0},
     {"the oldest block in the window still answers",
      fun history_getter_serves_oldest_in_window/0},
     {"read_parent_hash mirrors the contract's window",
      fun read_parent_hash_mirrors_the_window/0},
     {"no history call before Prague", fun no_history_call_before_prague/0},
     {"a missing history contract fails silently",
      fun missing_history_contract_fails_silently/0},
     {"the history call is wired into finalize",
      fun history_call_is_wired_into_finalize/0},
     {"the beacon-roots call is wired into finalize too",
      fun beacon_roots_are_wired_into_finalize/0},
     {"the block transition reads the scheduled fork",
      fun block_fork_follows_the_schedule/0}].

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
%% EIP-2935 block hash history
%% ---------------------------------------------------------------------------

%% The two system-contract rings in this file are keyed by different things, and
%% conflating them is the specific mistake available here. Beacon roots (4788) are
%% keyed by the block *timestamp*; parent hashes (2935) are keyed by the block
%% *number*. An implementation that reached for beacon_root_slots/1 when indexing
%% the history ring would compute a slot that no other client has ever written,
%% and the block would still validate.
history_ring_is_keyed_by_block_number() ->
    ?assertEqual(8191, eth_fork_schedule:history_serve_window()),
    ?assertEqual(?REAL_SLOT, eth_fork_schedule:history_slot(?REAL_NUMBER - 1)),
    %% The same block, indexed the other EIP's way. Block 0xb3ca35 has timestamp
    %% 1790382492, so the beacon-roots ring for it is keyed by 1790382492 while
    %% this ring is keyed by 11782708. Three different numbers, and the two
    %% contracts write to two different slots of two different accounts. An
    %% implementation that reached for beacon_root_slots/1 here would write
    %% 1903, a slot the EIP-2935 contract never reads.
    {BeaconSlot, _RootSlot} = eth_fork_schedule:beacon_root_slots(?REAL_TS_2935),
    ?assertEqual(1903, BeaconSlot),
    ?assertNotEqual(BeaconSlot, ?REAL_SLOT).

%% HISTORY_SERVE_WINDOW. Both the ring length and the width of the window the
%% getter will answer for come from it, so the two cannot drift apart.
history_window_is_8191() ->
    %% The getter answers for exactly 8191 block numbers: the 8191 just below the
    %% current one. Verified on Sepolia -- a query for the current number and one
    %% for number-8192 both revert, while number-1 and number-8191 both answer.
    ?assertEqual(8191, eth_fork_schedule:history_serve_window()).

%% The decisive test, as for 4788: run the bytecode the chain actually has
%% deployed at HISTORY_STORAGE_ADDRESS, and require the slot that a real
%% Sepolia block's state really contains.
history_reproduces_real_sepolia_block() ->
    with_ctx(fun() ->
        State = install_history_contract(blank()),
        {ok, S1} = eth_fork_schedule:process_history(
                     ?REAL_PARENT, ?REAL_NUMBER, State, prague),
        ?assertEqual(?REAL_SLOT,
                     eth_fork_schedule:history_slot(?REAL_NUMBER - 1)),
        ?assertEqual(binary:decode_unsigned(?REAL_PARENT),
                     eth_state:storage(S1, ?HISTORY, ?REAL_SLOT))
    end).

%% The other direction: the deployed getter, called the way anyone may call it,
%% has to return that same word for a block number inside the window. This is a
%% separate code path in the contract from the one above -- a different entry
%% point, reached by CALLER *not* being the system address -- and it is reached
%% by a branch condition on calldata size, so it is not implied by the write
%% path having worked.
history_getter_serves_parent_hash() ->
    with_ctx(fun() ->
        State = install_history_contract(blank()),
        {ok, S1} = eth_fork_schedule:process_history(
                     ?REAL_PARENT, ?REAL_NUMBER, State, prague),
        ?assertMatch({ok, ?REAL_PARENT},
                     history_get(?REAL_NUMBER - 1, ?REAL_NUMBER, S1))
    end).

%% Outside the window the contract reverts, and a client that answered anyway
%% would serve a ring slot that has been overwritten by an unrelated block, since
%% the ring is 8191 slots wide and the entry for that index belongs to some block
%% 8191 or more steps back.
history_getter_refuses_future_block() ->
    with_ctx(fun() ->
        State = install_history_contract(blank()),
        %% The block being processed is not in the ring yet; only its parent is.
        ?assertMatch({revert, _},
                     history_get(?REAL_NUMBER, ?REAL_NUMBER, State)),
        ?assertEqual({error, block_number_in_future},
                     eth_fork_schedule:read_parent_hash(
                       ?REAL_NUMBER, ?REAL_NUMBER, State))
    end).

history_getter_refuses_block_past_window() ->
    with_ctx(fun() ->
        State = install_history_contract(blank()),
        %% One past the 8191 the window covers.
        Old = ?REAL_NUMBER - 1 - 8191,
        ?assertMatch({revert, _},
                     history_get(Old, ?REAL_NUMBER, State)),
        ?assertEqual({error, block_number_too_old},
                     eth_fork_schedule:read_parent_hash(
                       Old, ?REAL_NUMBER, State))
    end).

%% The boundary is inclusive, and off-by-one here is not cosmetic: accepting one
%% block too many serves a slot that has been recycled.
history_getter_serves_oldest_in_window() ->
    with_ctx(fun() ->
        State = install_history_contract(blank()),
        Oldest = ?REAL_NUMBER - 1 - 8191 + 1,
        ?assertMatch({ok, _}, history_get(Oldest, ?REAL_NUMBER, State)),
        ?assertMatch({ok, _},
                     eth_fork_schedule:read_parent_hash(
                       Oldest, ?REAL_NUMBER, State))
    end).

%% read_parent_hash/3 is a shortcut around the contract, so it has to agree with
%% the contract about the window -- otherwise a caller using the shortcut gets
%% answers the on-chain getter would refuse, and vice versa.
read_parent_hash_mirrors_the_window() ->
    with_ctx(fun() ->
        State = install_history_contract(blank()),
        {ok, S1} = eth_fork_schedule:process_history(
                     ?REAL_PARENT, ?REAL_NUMBER, State, prague),
        ?assertEqual({ok, ?REAL_PARENT},
                     eth_fork_schedule:read_parent_hash(
                       ?REAL_NUMBER - 1, ?REAL_NUMBER, S1)),
        ?assertEqual({error, block_number_in_future},
                     eth_fork_schedule:read_parent_hash(
                       ?REAL_NUMBER, ?REAL_NUMBER, S1)),
        ?assertEqual({error, block_number_too_old},
                     eth_fork_schedule:read_parent_hash(
                       ?REAL_NUMBER - 8192, ?REAL_NUMBER, S1))
    end).

%% Prague is the fork that activates EIP-2935. Cancun blocks must not write the
%% ring, or this client's state root would disagree with every other client's
%% from the fork boundary onward.
no_history_call_before_prague() ->
    with_ctx(fun() ->
        State = install_history_contract(blank()),
        ?assertEqual({ok, State},
                     eth_fork_schedule:process_history(
                       ?REAL_PARENT, ?REAL_NUMBER, State, cancun)),
        ?assertEqual(0, eth_state:storage(State, ?HISTORY, ?REAL_SLOT))
    end).

%% "if no code exists at HISTORY_STORAGE_ADDRESS, the call must fail silently".
missing_history_contract_fails_silently() ->
    with_ctx(fun() ->
        State = blank(),
        ?assertEqual({ok, State},
                     eth_fork_schedule:process_history(
                       ?REAL_PARENT, ?REAL_NUMBER, State, prague))
    end).

%% The cases above call eth_fork_schedule directly. This one goes through
%% finalize/1, because the wiring is a separate thing to get right: a system call
%% that exists but is never invoked from the block transition leaves every
%% function-level case green while the state root stays wrong.
%%
%% It also pins the ordering claim. EIP-2935 and EIP-4788 both run before the
%% block's transactions, and the parent hash this block records is the one named
%% in its own header -- not the parent's, and not the parent's parent. Getting
%% that off by one hop would still write a plausible 32-byte word, just not the
%% right one, and the mismatch would only surface as a wrong state root.
history_call_is_wired_into_finalize() ->
    with_ctx(fun() ->
        Hash = eth_keccak:hash(?HISTORY_RUNTIME),
        ok = eth_mpt:put_code(Hash, ?HISTORY_RUNTIME),
        ok = eth_mpt:put_account(?HISTORY, 0, 1, Hash),
        Parent = store_parent(eth_mpt:state_root()),
        %% Timestamp 1790382492 is past Prague on Sepolia, so the fork selector
        %% the block transition consults really does have EIP-2935 active.
        Block = (eth_block:new(Parent, ?REAL_NUMBER))#block{
                   timestamp = ?REAL_TS_2935},
        {ok, _Finalized, V} = eth_block:finalize(Block),
        ?assertMatch({verified, _}, maps:get(state_root, V)),
        %% The word recorded is this block's own declared parent hash. The real
        %% Sepolia vector is exercised above against the real parent hash; here
        %% the point is that finalize/1 hands the header's parentHash to the
        %% contract rather than something else -- a different parent, or the
        %% block's own hash, would both write a plausible 32-byte word.
        ?assertEqual(Parent, mpt_word(?HISTORY, ?REAL_SLOT))
    end).

%% The same gap for EIP-4788, which was dead for the same reason and by the same
%% route. Its cases above call eth_fork_schedule directly, so nothing asserted
%% that finalize/1 makes the call at all -- and a block that never wrote its
%% beacon root computes a state root no other client computes, which is exactly
%% the failure this module exists to catch.
beacon_roots_are_wired_into_finalize() ->
    with_ctx(fun() ->
        Hash = eth_keccak:hash(?BEACON_RUNTIME),
        ok = eth_mpt:put_code(Hash, ?BEACON_RUNTIME),
        ok = eth_mpt:put_account(?BEACON, 0, 1, Hash),
        Parent = store_parent(eth_mpt:state_root()),
        Block = (eth_block:new(Parent, ?REAL_NUMBER))#block{
                   timestamp = ?REAL_TS,
                   parent_beacon_block_root = ?REAL_ROOT},
        {ok, _Finalized, V} = eth_block:finalize(Block),
        ?assertMatch({verified, _}, maps:get(state_root, V)),
        {TsSlot, RootSlot} = eth_fork_schedule:beacon_root_slots(?REAL_TS),
        ?assertEqual({3311, 11502}, {TsSlot, RootSlot}),
        ?assertEqual(?REAL_TS, binary:decode_unsigned(mpt_word(?BEACON, TsSlot))),
        ?assertEqual(?REAL_ROOT, mpt_word(?BEACON, RootSlot))
    end).

%% eth_block:fork/1 is the single input that decides which system calls a block%% makes, and it used to answer `paris' for every block at every fork. paris is
%% in neither EIP's active-fork list, so both system calls were skipped
%% everywhere -- and no test noticed, because the EIP-4788 and EIP-2935 cases
%% call eth_fork_schedule with an explicit fork and never go through this.
%%
%% Asserted against the schedule rather than against a literal fork name: which
%% fork a given timestamp lands in is configuration that may change, but the fact
%% that the block transition reads it correctly is the property here.
block_fork_follows_the_schedule() ->
    with_ctx(fun() ->
        Network = eth_fork_schedule:configured_network(),
        {ok, After} = eth_fork_schedule:current_fork(
                        Network, ?REAL_NUMBER, ?REAL_TS_2935),
        {ok, Before} = eth_fork_schedule:current_fork(
                         Network, 1, ?TS),
        %% Not a fixed expectation, but the two must differ, and neither may be
        %% the pre-fork answer this used to return for everything.
        ?assertNotEqual(Before, After),
        Late = (eth_block:new(<<"0x1">>, ?REAL_NUMBER))#block{
                  timestamp = ?REAL_TS_2935},
        Early = (eth_block:new(<<"0x1">>, 1))#block{timestamp = ?TS},
        ?assertEqual(After, eth_block:fork(Late)),
        ?assertEqual(Before, eth_block:fork(Early))
    end).

%% Call the deployed contract the way the network would: a caller that is not the
%% system address, asking about a block number.
%%
%% eth_evm:run returns the frame's full result tuple; what this contract's caller
%% observes is just the returned data, and whether the call succeeded at all.
%% Reducing it here keeps the window assertions below about the contract's
%% behaviour instead of about the interpreter's calling convention.
history_get(QueryNumber, AtBlockNumber, State) ->
    Msg = #{caller => ?PROBE,
            origin => ?PROBE,
            address => ?HISTORY,
            value => 0,
            data => <<QueryNumber:256>>,
            gas_price => 0,
            static => false,
            depth => 0},
    Env = #{timestamp => ?TS, number => AtBlockNumber,
            coinbase => <<0:160>>, prevrandao => <<0:256>>,
            gas_limit => 0, base_fee => 0,
            chain_id => eth_fork_schedule:chain_id(),
            state => State},
    case eth_evm:run(?HISTORY_RUNTIME, Msg, State, Env, 30000000) of
        {ok, Out, _Gas, _St, _Logs} -> {ok, Out};
        {revert, Out, _Gas, _St, _Logs} -> {revert, Out}
    end.

install_history_contract(State) ->
    Hash = eth_keccak:hash(?HISTORY_RUNTIME),
    ok = eth_mpt:put_code(Hash, ?HISTORY_RUNTIME),
    %% The EIP specifies nonce 1 for this account, matching the beacon-roots
    %% contract, so the account is installed the same way here.
    ok = eth_mpt:put_account(?HISTORY, 0, 1, Hash),
    eth_state:set_code(State, ?HISTORY, ?HISTORY_RUNTIME).

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

%% A committed storage word, normalised to 32 bytes. The MPT returns a slot's
%% contents with leading zero bytes stripped, so comparing a raw read against a
%% full 32-byte word would fail on any value that happens to start with a zero --
%% which is one value in 256, and is the case for the beacon-roots timestamp.
%%
%% The padding is on the left, because the stripped bytes are the leading ones.
%% Padding on the right instead would leave a value that compares equal only when
%% the leading byte happened to be non-zero, which is precisely the case a
%% hand-written assertion would be tested against.
mpt_word(Addr, Slot) ->
    case eth_mpt:get_storage(Addr, <<Slot:256>>) of
        <<>> -> <<0:256>>;
        Bytes -> <<0:((32 - byte_size(Bytes)) * 8), Bytes/binary>>
    end.

%% Finalize a block carrying N identical calls to the installed contract.
run_block(N, Parent, Number, Timestamp, Calldata) ->
    Txs = [signed_call(Calldata, Nonce) || Nonce <- lists:seq(0, N - 1)],
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
%%
%% This was originally an *unprotected* legacy transaction (v = 27 + recid), which
%% is what eth_tx:validate/2 correctly refuses on a chain that has a chain id:
%% EIP-155 replay protection exists precisely to stop an unprotected transaction
%% being replayed onto another chain, so "no chain id" is not a pass. The fixture
%% was never a transaction a real network would accept; signing for the
%% configured chain is what makes it one.
signed_call(Calldata, Nonce) ->
    {PrivKey, _Sender} = get(?MODULE),
    GasPrice = 0,
    Gas = 1000000,
    Value = 0,
    To = ?PROBE,
    ChainId = eth_fork_schedule:chain_id(),
    Digest = eth_keccak:hash(
               eth_rlp:encode([Nonce, GasPrice, Gas, To, Value, Calldata,
                               ChainId, 0, 0])),
    {R, S, V} = eth_secp256k1:sign(Digest, PrivKey),
    #{<<"type">> => <<"0x0">>,
      <<"nonce">> => eth_hex:encode_int(Nonce),
      <<"gasPrice">> => eth_hex:encode_int(GasPrice),
      <<"gas">> => eth_hex:encode_int(Gas),
      <<"to">> => hex(To),
      <<"value">> => eth_hex:encode_int(Value),
      <<"input">> => hex(Calldata),
      %% EIP-155: v = chainId * 2 + 35 + recid.
      <<"v">> => eth_hex:encode_int(ChainId * 2 + 35 + V),
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
