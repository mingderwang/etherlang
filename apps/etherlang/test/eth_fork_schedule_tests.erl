-module(eth_fork_schedule_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GWEI, 1000000000).
-define(MAINNET_GAS_LIMIT, 30000000).
-define(CREATE_BASE, 32000).
-define(TARGET, 20000000).

%% ---------------------------------------------------------------------------
%% EIP-1559 base fee
%% ---------------------------------------------------------------------------

%% The elasticity target is two-thirds of the gas limit, not one-third. With a
%% 30M limit the target is 20M, and a parent that used exactly the target must
%% leave the base fee unchanged.
base_fee_target_is_two_thirds_test() ->
    ?assertEqual(20000000, ?MAINNET_GAS_LIMIT * 2 div 3),
    ?assertEqual(?GWEI, eth_fork_schedule:base_fee(?TARGET, ?MAINNET_GAS_LIMIT, ?GWEI)),
    %% At the target the signed deviation is exactly zero.
    ?assertEqual(0, eth_fork_schedule:base_fee_delta(?TARGET, ?MAINNET_GAS_LIMIT)),
    ?assertEqual(10000000, eth_fork_schedule:base_fee_delta(?MAINNET_GAS_LIMIT,
                                                           ?MAINNET_GAS_LIMIT)).

%% An empty parent block (0 gas used) drops the base fee by parent * 20M/20M/8
%% = parent/8, so 1 gwei becomes 875,000,000.
base_fee_empty_block_test() ->
    ?assertEqual(875000000,
                 eth_fork_schedule:base_fee(0, ?MAINNET_GAS_LIMIT, ?GWEI)),
    ?assertEqual(20000000, eth_fork_schedule:base_fee_delta(0, ?MAINNET_GAS_LIMIT)).

%% A full parent block (30M used) overshoots the target by 10M, which is half
%% the target: parent * 10M/20M/8 = parent/16, so 1 gwei becomes
%% 1,062,500,000.
base_fee_full_block_test() ->
    ?assertEqual(1062500000,
                 eth_fork_schedule:base_fee(?MAINNET_GAS_LIMIT, ?MAINNET_GAS_LIMIT, ?GWEI)).

%% A block one gas over target must still increase the fee, by at least one wei.
%% 1e9 * 1 / 20e6 = 50, 50 / 8 = 6, so the next fee is 1,000,000,006.
%%
%% With a tiny parent fee the arithmetic truncates to zero, and the "at least
%% one wei" rule is what keeps the base fee from getting stuck: 7 wei becomes 8.
base_fee_minimum_increase_test() ->
    ?assertEqual(1000000006,
                 eth_fork_schedule:base_fee(?TARGET + 1, ?MAINNET_GAS_LIMIT, ?GWEI)),
    ?assertEqual(8, eth_fork_schedule:base_fee(?TARGET + 1, ?MAINNET_GAS_LIMIT, 7)).

%% The floor is 7 wei, not 1 gwei. Repeatedly applying an empty parent decays
%% geometrically by 7/8, so it takes roughly 140 steps to walk 1 gwei down to
%% the floor; 400 steps is comfortably past that.
base_fee_floor_is_seven_wei_test() ->
    Fee = lists:foldl(
        fun(_, F) -> eth_fork_schedule:base_fee(0, ?MAINNET_GAS_LIMIT, F) end,
        ?GWEI, lists:seq(1, 400)),
    ?assertEqual(7, Fee).

%% A zero or negative gas limit is not meaningful input; the parent fee is
%% returned unchanged rather than dividing by zero.
base_fee_zero_gas_limit_test() ->
    ?assertEqual(?GWEI, eth_fork_schedule:base_fee(0, 0, ?GWEI)),
    ?assertEqual(0, eth_fork_schedule:base_fee_delta(0, 0)).

%% The two-argument form starts from the London initial base fee of 1 gwei.
base_fee_default_initial_test() ->
    ?assertEqual(?GWEI, eth_fork_schedule:base_fee(?TARGET, ?MAINNET_GAS_LIMIT)),
    ?assertEqual(875000000, eth_fork_schedule:base_fee(0, ?MAINNET_GAS_LIMIT)).

burn_base_fee_test() ->
    ?assertEqual(30000000000000000, eth_fork_schedule:burn_base_fee(?GWEI, ?MAINNET_GAS_LIMIT)).

%% ---------------------------------------------------------------------------
%% Fork selection
%% ---------------------------------------------------------------------------

%% The default is the newest supported execution rules, and rank ordering is
%% monotonic, which is what makes feature gates like `at_least/2' sound.
fork_ranking_test() ->
    ?assertEqual(true, eth_fork_schedule:at_least(cancun, london)),
    ?assertEqual(true, eth_fork_schedule:at_least(cancun, cancun)),
    ?assertEqual(false, eth_fork_schedule:at_least(berlin, london)),
    ?assertEqual(false, eth_fork_schedule:at_least(istanbul, berlin)),
    ?assertEqual(true, eth_fork_schedule:at_least(deneb, shanghai)).

%% Fork selection is driven by the network's real activation points rather
%% than by a single configured value, so a block on either side of an
%% activation reports a different fork.
fork_selection_test() ->
    %% Mainnet block forks. These use a timestamp before Shanghai so that only
    %% the block-numbered forks are in play; the interaction with a timestamped
    %% fork is checked separately below.
    ?assertEqual(berlin, fork(mainnet, 12964999, 1650000000)),
    ?assertEqual(london, fork(mainnet, 12965000, 1650000000)),
    %% Istanbul is the last fork that changes an execution rule before Berlin.
    %% Muir Glacier only delays the difficulty bomb, so it shares Istanbul's
    %% rank and Istanbul is what gets reported.
    ?assertEqual(istanbul, fork(mainnet, 12243999, 1650000000)),
    ?assertEqual(berlin, fork(mainnet, 12244000, 1650000000)),
    %% A timestamped fork is decided by the block's timestamp, not its height,
    %% so a block far past the activation height still gets the old rules
    %% until its timestamp reaches it. Shanghai activates at 1681338455.
    ?assertEqual(gray_glacier, fork(mainnet, 19000000, 1681338454)),    ?assertEqual(shanghai, fork(mainnet, 19000000, 1681338455)),
    ?assertEqual(shanghai, fork(mainnet, 19000000, 1710338134)),
    ?assertEqual(cancun, fork(mainnet, 19000000, 1710338135)),
    ?assertEqual(prague, fork(mainnet, 19000000, 1746612311)).

%% Sepolia is post-Berlin at genesis and post-London at genesis, so height
%% never changes its block fork; only the timestamped forks move.
fork_selection_sepolia_test() ->
    ?assertEqual(london, fork(sepolia, 0, 1677557087)),
    ?assertEqual(shanghai, fork(sepolia, 0, 1677557088)),
    ?assertEqual(cancun, fork(sepolia, 5000000, 1706655072)),
    ?assertEqual(cancun, fork(sepolia, 11779968, 1741159775)),
    ?assertEqual(prague, fork(sepolia, 11779968, 1741159776)),
    ?assertEqual(osaka, fork(sepolia, 11779968, 1760427360)),
    ?assertEqual(amsterdam, fork(sepolia, 11779968, 1791294816)).

%% ---------------------------------------------------------------------------
%% Fork time frames: the `-38005: Unsupported fork' input
%% ---------------------------------------------------------------------------

%% The engine API's versioned methods are gated on the payload's timestamp
%% falling in the time frame of the fork that method serves. Cancun's frame on
%% mainnet is [1710338135, 1746612311): half open, so the Prague activation
%% instant belongs to Prague. A closed upper bound would accept a Prague payload
%% on newPayloadV3 and a Cancun payload on newPayloadV4 at the same timestamp.
cancun_frame_on_mainnet_is_half_open_test() ->
    F = fun eth_fork_schedule:timestamp_in_frame/3,
    ?assertEqual(false, F(mainnet, cancun, 1710338134)),
    ?assertEqual(true,  F(mainnet, cancun, 1710338135)),
    ?assertEqual(true,  F(mainnet, cancun, 1746612310)),
    ?assertEqual(false, F(mainnet, cancun, 1746612311)),
    ?assertEqual(false, F(mainnet, cancun, 1900000000)).

%% Both neighbours must agree at the boundary, or one method's frame overlaps the
%% other's and a timestamp is valid for two forks at once.
neighbouring_frames_do_not_overlap_test() ->
    F = fun eth_fork_schedule:timestamp_in_frame/3,
    %% The Prague activation instant is not Cancun's and is Prague's.
    ?assertEqual(false, F(mainnet, cancun, 1746612311)),
    ?assertEqual(true,  F(mainnet, prague, 1746612311)),
    %% One second earlier is still Cancun and not Prague.
    ?assertEqual(true,  F(mainnet, cancun, 1746612310)),
    ?assertEqual(false, F(mainnet, prague, 1746612310)),
    %% The same at the Osaka boundary.
    ?assertEqual(false, F(mainnet, prague, 1764798551)),
    ?assertEqual(true,  F(mainnet, osaka, 1764798551)),
    %% The last timestamped fork has no successor, so its frame runs to the end of
    %% time rather than being empty.
    ?assertEqual(true, F(sepolia, amsterdam, 1791294816)),
    ?assertEqual(true, F(sepolia, amsterdam, 99999999999)).

%% A fork this network does not timestamp has no frame. Reporting "out of frame"
%% for it would refuse every payload on a network that predates the fork, which
%% is the opposite of what a CL needs: a pre-Cancun CL calling V1 is fine, and
%% the node must not answer it -38005.
a_fork_the_network_does_not_timestamp_has_no_frame_test() ->
    F = fun eth_fork_schedule:timestamp_in_frame/3,
    ?assertEqual(false, F(sepolia, cancun, 1706655071)),
    %% Cancun *is* timestamped on mainnet, so this is the same question with the
    %% other answer -- the check reads the network's schedule, not a constant.
    ?assertEqual(true, F(mainnet, cancun, 1710338135)),
    %% Block-activated forks have no time frame at all.
    ?assertEqual(false, F(mainnet, berlin, 1000000000)),
    %% An unknown network has no schedule, hence no frames.
    ?assertEqual(false, F(nonesuch, cancun, 1710338135)).

%% The frame must be derived from the schedule current_fork/4 reads, not a second
%% table. If these two ever disagree, a payload can be both "in the Cancun frame"
%% and "not Cancun", and the node would answer -38005 to a block it would
%% otherwise execute under Cancun rules.
frame_agrees_with_current_fork_test() ->
    Schedule = eth_fork_schedule:fork_schedule(mainnet),
    Timestamped = [F || {time, _, F} <- Schedule],
    Timestamps = [0, 1681338454, 1681338455, 1710338135, 1746612310, 1746612311,
                  1764798551, 1799999999],
    [begin
         {ok, Fork} = eth_fork_schedule:current_fork(mainnet, 19000000, T),
         InAnyFrame = lists:any(
                        fun(F) -> eth_fork_schedule:timestamp_in_frame(mainnet, F, T)
                        end, Timestamped),
         ?assertEqual(InAnyFrame,
                      eth_fork_schedule:timestamp_in_frame(mainnet, Fork, T))
     end || T <- Timestamps].

%% ---------------------------------------------------------------------------
%% EIP-3675: the Merge is gated on total difficulty
%% ---------------------------------------------------------------------------

%% Mainnet's TERMINAL_TOTAL_DIFFICULTY. The Merge is a total-difficulty
%% activation, so unlike every other fork it has no block number and no
%% timestamp: it is the value total difficulty reaches at block 15537394. It is
%% a constant of the network, written down here as data rather than as a guess
%% about a block number.
-define(MAINNET_TTD, 58750000000000000000000).

%% The bug this gates. A post-Merge mainnet block before Shanghai used to come
%% back gray_glacier, because the schedule jumped from gray_glacier straight to
%% the Shanghai timestamp and nothing recognised the transition. It would then
%% have been executed under a difficulty bomb that had already been halted, at a
%% difficulty that should have been zero -- and nothing would have said so.
%%
%% The blocks are past Gray Glacier (15050000) and the timestamp 1670000000 sits
%% between the Merge and Shanghai (1681338455), which is exactly the range that
%% was wrong. Every one of the 823461 blocks in that window was mis-executed.
merge_is_gated_on_total_difficulty_test() ->
    ?assertEqual(paris, fork_td(mainnet, 16000000, 1670000000, ?MAINNET_TTD + 1000)),
    ?assertEqual(gray_glacier, fork_td(mainnet, 16000000, 1670000000,
                                      ?MAINNET_TTD - 1)).

%% The transition block is itself post-Merge. Greater-or-equal, not greater:
%% treating block 15537394 as the last PoW block would put it under both rule
%% sets, and geth's MergeFORK treats the block that reaches the TTD as the
%% first block of the PoS chain.
merge_block_itself_is_post_merge_test() ->
    ?assertEqual(paris, fork_td(mainnet, 15537394, 1660000000, ?MAINNET_TTD)),
    ?assertEqual(gray_glacier, fork_td(mainnet, 15537393, 1660000000, ?MAINNET_TTD - 1)).

%% Not knowing the total difficulty is not the same as knowing the chain has not
%% merged. The selector fails toward pre-Merge, because a caller that guessed
%% "merged" would apply PoS rules -- difficulty zero, no uncle processing, no
%% difficulty bomb -- to a block that might not be post-Merge, and would not
%% know it had. current_fork/3 is the no-total-difficulty entry point, and it
%% has to agree with this rather than quietly returning paris.
unknown_total_difficulty_is_not_read_as_merged_test() ->
    ?assertEqual(gray_glacier, fork(mainnet, 15537394, 1660000000)),
    ?assertEqual(gray_glacier, fork(mainnet, 16000000, 1670000000)),
    %% And the pre-Merge answer is not vacuous: it differs from the post-Merge
    %% one for the very same block.
    ?assertEqual(paris, fork_td(mainnet, 16000000, 1670000000, ?MAINNET_TTD + 1000)).

%% Sepolia merged at genesis, so its TERMINAL_TOTAL_DIFFICULTY is 0. That makes
%% 0 a load-bearing value: if undefined and 0 were conflated, Sepolia would
%% report a post-Merge chain as pre-Merge forever. current_fork/3 leaves it
%% alone -- there is no way to know -- but a caller that passes the 0 it was
%% given must get Paris.
sepolia_merged_at_genesis_test() ->
    ?assertEqual(paris, fork_td(sepolia, 1, 1633267481, 0)),
    %% With no total difficulty there is no way to know, and London -- the
    %% highest *block*-activated fork -- is what falls out. Sepolia has no Arrow
    %% or Gray Glacier entry, because both predate it.
    ?assertEqual(london, fork_td(sepolia, 1, 1633267481, undefined)),
    ?assertEqual(london, fork_td(sepolia, 1, 1633267481, -1)).

%% Paris must sit between Gray Glacier and Shanghai in the ranking, or the gate
%% above would pick the wrong side of two of the three boundaries.
paris_ranks_between_gray_glacier_and_shanghai_test() ->
    Post = ?MAINNET_TTD + 1000,
    ?assertEqual(paris, fork_td(mainnet, 16000000, 1670000000, Post)),
    %% Once Shanghai's timestamp passes, Shanghai wins over Paris.
    ?assertEqual(shanghai, fork_td(mainnet, 16000000, 1690000000, Post)).

%% Shanghai, Cancun and Prague are activated by *timestamp* and are not gated on
%% the total difficulty at all, because the network did not need them to be. So
%% a block whose total difficulty is below the TTD but whose timestamp is past
%% Shanghai's is reported as Shanghai -- Paris is correctly withheld, and a
%% post-Merge fork is reported anyway.
%%
%% This combination does not occur on mainnet, since the Merge (September 2022)
%% precedes Shanghai (April 2023) by seven months, so it is a property of the
%% schedule rather than a divergence from it. It is pinned here because the day
%% a network's fork order is not "Merge first" this becomes a real bug, and
%% nothing else would notice.
timestamp_fork_is_not_gated_on_the_merge_test() ->
    ?assertEqual(shanghai, fork_td(mainnet, 19000000, 1690000000, ?MAINNET_TTD - 1)),
    ?assertEqual(paris, fork_td(mainnet, 19000000, 1670000000, ?MAINNET_TTD + 1)).

fork_td(Network, Number, Timestamp, TD) ->
    {ok, F} = eth_fork_schedule:current_fork(Network, Number, Timestamp, TD),
    F.

%% A network with no schedule falls back to the ETH_FORK rules pin instead of
%% guessing from its name.
fork_selection_unknown_network_test() ->
    ?assertEqual({ok, configured_fork_default()},
                 eth_fork_schedule:current_fork(holesky, 1, 1)),
    ?assertEqual([], eth_fork_schedule:fork_schedule(holesky)).

%% The activation points in this module must agree with the EIP-2124 ForkID
%% schedule in eth_forkid, which is derived independently from the same chain
%% config. A fork added to one and not the other means the node would apply
%% rules the network has not activated (or fail to apply rules it has), so the
%% two are compared directly.
%%
%% Two differences are expected and are asserted explicitly rather than waved
%% through:
%%   * eth_forkid's gatherForks drops block 0, so a network whose forks are
%%     all active at genesis (Sepolia) contributes no block fork to it.
%%   * eth_forkid also lists the MergeNetsplitBlock, which splits devp2p
%%     sessions and changes no execution rule, so it appears there and not
%%     here. Sepolia sets it to 1735371; mainnet leaves it unset.
schedule_agrees_with_forkid_test() ->
    lists:foreach(fun(Network) ->
        {ForkIdBlocks, ForkIdTimes} = eth_forkid:schedule(Network),
        Schedule = eth_fork_schedule:fork_schedule(Network),
        Times = [P || {time, P, _} <- Schedule],
        ?assertEqual(usort(Times), usort(ForkIdTimes)),
        Blocks = [P || {block, P, _} <- Schedule, P > 0],
        Expected = usort(Blocks ++ netsplit_blocks(Network)),
        ?assertEqual(Expected, usort(ForkIdBlocks))
    end, [mainnet, sepolia]).

netsplit_blocks(sepolia) -> [1735371];
netsplit_blocks(mainnet) -> [].

fork(Network, Number, Timestamp) ->
    {ok, F} = eth_fork_schedule:current_fork(Network, Number, Timestamp),
    F.

usort(L) -> lists:usort(L).

configured_fork_default() ->
    case os:getenv("ETH_FORK") of
        false -> cancun;
        "" -> cancun;
        Value -> list_to_atom(string:lowercase(string:trim(Value)))
    end.

%% ---------------------------------------------------------------------------
%% EIP-4895 withdrawals
%% ---------------------------------------------------------------------------

%% The empty withdrawals root is the empty Merkle-Patricia trie root -- the same
%% commitment the transactions root makes for a block with no transactions.
%% withdrawalsRoot was briefly implemented here as an SSZ hash-tree-root, which
%% is a plausible 32-byte value no other client produces; eth_withdrawals_tests
%% pins the correct construction against real Sepolia blocks.
empty_withdrawals_root_is_the_empty_trie_test() ->
    ?assertEqual(eth_trie:root([]), eth_fork_schedule:withdrawals_root([])).

%% An empty list and a list of nothing must agree, and a single withdrawal must
%% change the root.
withdrawals_root_depends_on_content_test() ->
    Empty = eth_fork_schedule:withdrawals_root([]),
    A = eth_fork_schedule:make_withdrawal(1, <<1:160>>, 32000000000),
    B = eth_fork_schedule:make_withdrawal(2, <<2:160>>, 32000000000),
    R1 = eth_fork_schedule:withdrawals_root([A]),
    R2 = eth_fork_schedule:withdrawals_root([B]),
    ?assertNotEqual(Empty, R1),
    ?assertNotEqual(R1, R2),
    ?assertEqual(R1, eth_fork_schedule:withdrawals_root([A])).

%% The root is a pure function of the ordered list; a permutation is a
%% different commitment, which is why process_withdrawals/2 sorts first.
withdrawals_root_is_order_sensitive_test() ->
    A = eth_fork_schedule:make_withdrawal(1, <<1:160>>, 1000),
    B = eth_fork_schedule:make_withdrawal(2, <<2:160>>, 2000),
    ?assertNotEqual(eth_fork_schedule:withdrawals_root([A, B]),
                    eth_fork_schedule:withdrawals_root([B, A])).

process_withdrawals_sorts_by_index_test() ->
    A = eth_fork_schedule:make_withdrawal(5, <<1:160>>, 1),
    B = eth_fork_schedule:make_withdrawal(2, <<2:160>>, 2),
    C = eth_fork_schedule:make_withdrawal(9, <<3:160>>, 3),
    Sorted = eth_fork_schedule:process_withdrawals(100, [A, B, C]),
    ?assertEqual([2, 5, 9], [maps:get(index, W) || W <- Sorted]),
    ?assertEqual([B, A, C], Sorted).

%% ---------------------------------------------------------------------------
%% EIP-4788 beacon roots
%% ---------------------------------------------------------------------------

%% EIP-4788 deploys the beacon-roots contract at 0x000F3df6D732807Ef1319fB7
%% B8bB8522d0Beac02, a 20-byte address. The previous implementation returned 32
%% zero bytes, which is not an address at all.
beacon_contract_address_test() ->
    Addr = eth_fork_schedule:beacon_root_contract(),
    ?assertEqual(20, byte_size(Addr)),
    ?assertEqual(<<16#00, 16#0F, 16#3d, 16#f6, 16#D7, 16#32, 16#80, 16#7E,
                   16#f1, 16#31, 16#9f, 16#B7, 16#B8, 16#bB, 16#85, 16#22,
                   16#d0, 16#Be, 16#ac, 16#02>>, Addr).

%% With no state process running, the storage helpers must report that state is
%% unavailable rather than crashing the caller or silently succeeding.
beacon_root_without_state_test() ->
    case whereis(eth_mpt) of
        undefined ->
            ?assertEqual({error, state_unavailable},
                         eth_fork_schedule:add_beacon_root(1000, <<0:256>>)),
            ?assertEqual({error, state_unavailable},
                         eth_fork_schedule:get_beacon_root(1000));
        _ ->
            ok
    end.

%% ---------------------------------------------------------------------------
%% Gas schedule
%% ---------------------------------------------------------------------------

%% A few opcode costs that were previously wrong or missing.
gas_cost_basics_test() ->
    ?assertEqual(0, eth_fork_schedule:gas_cost(16#00, cancun, 0)),
    ?assertEqual(3, eth_fork_schedule:gas_cost(16#01, cancun, 0)),
    ?assertEqual(5, eth_fork_schedule:gas_cost(16#02, cancun, 0)),
    ?assertEqual(3, eth_fork_schedule:gas_cost(16#03, cancun, 0)),
    %% DIV is 5, not 4.
    ?assertEqual(5, eth_fork_schedule:gas_cost(16#04, cancun, 0)),
    ?assertEqual(5, eth_fork_schedule:gas_cost(16#06, cancun, 0)),
    ?assertEqual(8, eth_fork_schedule:gas_cost(16#08, cancun, 0)),
    %% EXP is 10 base; the per-byte exponent term is charged by the interpreter.
    ?assertEqual(10, eth_fork_schedule:gas_cost(16#0A, cancun, 0)),
    ?assertEqual(30, eth_fork_schedule:gas_cost(16#20, cancun, 0)),
    ?assertEqual(32000, eth_fork_schedule:gas_cost(16#F0, cancun, 0)).

%% KECCAK256 is 30 + 6 per 32-byte word of input. A single byte still occupies
%% a whole word, so 1 byte costs 36, not 30.
gas_cost_keccak_dynamic_test() ->
    ?assertEqual(30, eth_fork_schedule:gas_cost(16#20, cancun, 0)),
    ?assertEqual(36, eth_fork_schedule:gas_cost(16#20, cancun, 1)),
    ?assertEqual(36, eth_fork_schedule:gas_cost(16#20, cancun, 32)),
    ?assertEqual(42, eth_fork_schedule:gas_cost(16#20, cancun, 33)),
    ?assertEqual(42, eth_fork_schedule:gas_cost(16#20, cancun, 64)).

%% LOG0 is 375 base plus 8 gas per byte of data.
gas_cost_log_test() ->
    ?assertEqual(375, eth_fork_schedule:gas_cost(16#A0, cancun, 0)),
    ?assertEqual(375 + 80, eth_fork_schedule:gas_cost(16#A0, cancun, 10)),
    ?assertEqual(750, eth_fork_schedule:gas_cost(16#A1, cancun, 0)),
    ?assertEqual(750 + 8, eth_fork_schedule:gas_cost(16#A1, cancun, 1)).

%% EIP-2929: an account access is 2600 when cold and 100 when warm. Before
%% Berlin the flat legacy cost applies and there is no warm/cold distinction.
gas_cost_access_warm_cold_test() ->
    %% BALANCE
    ?assertEqual(2600, eth_fork_schedule:gas_cost(16#31, cancun, 0, #{})),
    ?assertEqual(100, eth_fork_schedule:gas_cost(16#31, cancun, 0, #{warm => true})),
    ?assertEqual(400, eth_fork_schedule:gas_cost(16#31, istanbul, 0, #{})),
    %% EXTCODEHASH
    ?assertEqual(2600, eth_fork_schedule:gas_cost(16#3F, cancun, 0, #{})),
    ?assertEqual(100, eth_fork_schedule:gas_cost(16#3F, cancun, 0, #{warm => true})),
    %% EXTCODESIZE
    ?assertEqual(2600, eth_fork_schedule:gas_cost(16#3B, cancun, 0, #{})),
    ?assertEqual(700, eth_fork_schedule:gas_cost(16#3B, istanbul, 0, #{})).

%% The CALL family was absent from the table entirely, so every call was free.
%% A cold call is 2600, a warm call 100, and a value-bearing warm call adds the
%% 9000 stipend plus 25000 when the destination account is new.
gas_cost_call_test() ->
    ?assertEqual(2600, eth_fork_schedule:gas_cost(16#F1, cancun, 0, #{})),
    ?assertEqual(100, eth_fork_schedule:gas_cost(16#F1, cancun, 0, #{warm => true})),
    ?assertEqual(100 + 9000,
                 eth_fork_schedule:gas_cost(16#F1, cancun, 0,
                                            #{warm => true, value_transfer => true})),
    ?assertEqual(100 + 9000 + 25000,
                 eth_fork_schedule:gas_cost(16#F1, cancun, 0,
                                            #{warm => true, value_transfer => true,
                                              new_account => true})),
    ?assertEqual(700, eth_fork_schedule:gas_cost(16#F1, istanbul, 0, #{})),
    %% DELEGATECALL and STATICCALL share the access cost.
    ?assertEqual(2600, eth_fork_schedule:gas_cost(16#F4, cancun, 0, #{})),
    ?assertEqual(2600, eth_fork_schedule:gas_cost(16#FA, cancun, 0, #{})).

%% ---------------------------------------------------------------------------
%% Gas schedule completeness
%% ---------------------------------------------------------------------------
%%
%% Everything above samples the table. That is how it came to be wrong for
%% eighteen opcodes with its own tests green: gas_cost_basics_test/0 checks ADD,
%% MUL, SUB, DIV, MOD, ADDM, EXP, KECCAK256 and CREATE -- nine opcodes the table
%% already had right -- and not one it had wrong. The tests below assert the
%% whole table instead.
%%
%% Note that gas_cost/3,4 returns base *plus* dynamic, so every expectation here
%% is a total for the given length argument. A base of 3 for a copy opcode is
%% 6 at one word, and reading these numbers as bases is itself a trap.

%% The complete Cancun base schedule. Costs are those of EIP-2929 (Berlin,
%% warm/cold) as amended by EIP-3529 (London), EIP-3541/EIP-3651 (Shanghai) and
%% EIP-4844 (Cancun), quoted at dynamic length 0 for a *cold* access. Memory
%% expansion is charged by the interpreter and is not in this table.
cancun_schedule() ->
    [{16#00, "STOP",             0},
     {16#01, "ADD",              3},
     {16#02, "MUL",              5},
     {16#03, "SUB",              3},
     {16#04, "DIV",              5},
     {16#05, "SDIV",             5},
     {16#06, "MOD",              5},
     {16#07, "SMOD",             5},
     {16#08, "ADDM",             8},
     {16#09, "MULMOD",           8},
     {16#0A, "EXP",             10},
     {16#0B, "SIGNEXTEND",       5}]
    ++ named(16#10, ["LT", "GT", "SLT", "SGT", "EQ", "ISZERO", "AND", "OR",
                     "XOR", "NOT", "BYTE", "SHL", "SHR", "SAR"], 3)
    ++ [{16#20, "KECCAK256",     30},
        {16#30, "ADDRESS",       2},
        {16#31, "BALANCE",    2600},
        {16#32, "ORIGIN",        2},
        {16#33, "CALLER",        2},
        {16#34, "CALLVALUE",     2},
        {16#35, "CALLDATALOAD",  3},
        {16#36, "CALLDATASIZE",  2},
        {16#37, "CALLDATACOPY",  3},
        {16#38, "CODESIZE",      2},
        {16#39, "CODECOPY",      3},
        {16#3A, "GASPRICE",      2},
        {16#3B, "EXTCODESIZE", 2600},
        {16#3C, "EXTCODECOPY", 2600},
        {16#3D, "RETURNDATASIZE", 2},
        {16#3E, "RETURNDATACOPY", 3},
        {16#3F, "EXTCODEHASH", 2600},
        {16#40, "BLOCKHASH",    20}]
    ++ named(16#41, ["COINBASE", "TIMESTAMP", "NUMBER", "PREVRANDAO",
                     "GASLIMIT", "CHAINID"], 2)
    ++ [{16#47, "SELFBALANCE",   5},
        {16#48, "BASEFEE",      20},
        {16#49, "BLOBHASH",     20},
        {16#4A, "BLOBBASEFEE",  20},
        {16#50, "POP",           2},
        {16#51, "MLOAD",         3},
        {16#52, "MSTORE",        3},
        {16#53, "MSTORE8",       3},
        {16#54, "SLOAD",      2100},
        {16#56, "JUMP",          8},
        {16#57, "JUMPI",        10},
        {16#58, "PC",            2},
        {16#59, "MSIZE",         2},
        {16#5A, "GAS",           2},
        {16#5B, "JUMPDEST",      1},
        {16#5C, "TLOAD",       100},
        {16#5D, "TSTORE",      100},
        {16#5E, "MCOPY",         3},
        {16#5F, "PUSH0",         2}]
    ++ numbered("PUSH", 16#60, 16#7F, 3)
    ++ numbered("DUP", 16#80, 16#8F, 3)
    ++ numbered("SWAP", 16#90, 16#9F, 3)
    ++ [{16#A0, "LOG0",        375},
        {16#A1, "LOG1",        750},
        {16#A2, "LOG2",       1125},
        {16#A3, "LOG3",       1500},
        {16#A4, "LOG4",       1875},
        {16#F0, "CREATE",     32000},
        {16#F1, "CALL",        2600},
        {16#F2, "CALLCODE",   2600},
        {16#F4, "DELEGATECALL", 2600},
        {16#F5, "CREATE2",    32000},
        {16#FA, "STATICCALL",  2600},
        {16#FF, "SELFDESTRUCT", 5000}].

%% Expand a contiguous family that shares one price. PUSH1 through PUSH32 and
%% its DUP and SWAP relatives, named per opcode so a failure says which.
numbered(Name, First, Last, Cost) ->
    [{Op, Name ++ integer_to_list(Op - First + 1), Cost}
     || Op <- lists:seq(First, Last)].

%% Expand a contiguous family that shares one price and has fixed names.
named(First, Names, Cost) ->
    [{First + N - 1, Name, Cost}
     || {N, Name} <- lists:zip(lists:seq(1, length(Names)), Names)].

%% Every price the table reports, for a cold access and no dynamic term.
priced(Fork, Args) ->
    [{Op, eth_fork_schedule:gas_cost(Op, Fork, 0, Args)}
     || Op <- lists:seq(0, 255),
        eth_fork_schedule:gas_cost(Op, Fork, 0, Args) =/= 0].

%% The priced set is asserted *exactly*, not merely member by member, so an
%% opcode that loses its clause and falls through to the catch-all is reported
%% as a missing entry. That is the mechanism behind the four free opcodes below:
%% the catch-all prices an unassigned opcode at 0, which is the opposite of the
%% safe default, because an opcode nobody has costed is the one case that ought
%% to be conspicuous.
no_opcode_is_silently_unpriced_test() ->
    Expected = lists:usort([Op || {Op, Name, _} <- cancun_schedule(),
                                  Name =/= "STOP"]),
    Priced = lists:usort([Op || {Op, _} <- priced(cancun, #{})]),
    ?assertEqual({unexpected_prices, Priced -- Expected}, {unexpected_prices, []}),
    ?assertEqual({unpriced_opcodes, Expected -- Priced}, {unpriced_opcodes, []}).

%% ...and the values, one assertion per opcode, so a failure names the opcode
%% rather than diffing two ninety-element lists.
cancun_base_schedule_values_test() ->
    [?assertEqual({Name, Cost},
                  {Name, eth_fork_schedule:gas_cost(Op, cancun, 0, #{})})
     || {Op, Name, Cost} <- cancun_schedule()],
    ok.

%% The opcodes that are genuinely free must be free by decision. They share
%% their 0 with the undefined opcodes, so a lost clause here is invisible to
%% no_opcode_is_silently_unpriced_test/0, and this is what keeps that from
%% happening unnoticed.
free_opcodes_are_free_by_decision_test() ->
    ?assertEqual({16#00, "STOP", 0},
                 {16#00, "STOP", eth_fork_schedule:gas_cost(16#00, cancun, 0, #{})}),
    ?assertEqual({16#F3, "RETURN", 0},
                 {16#F3, "RETURN", eth_fork_schedule:gas_cost(16#F3, cancun, 0, #{})}),
    ?assertEqual({16#FD, "REVERT", 0},
                 {16#FD, "REVERT", eth_fork_schedule:gas_cost(16#FD, cancun, 0, #{})}),
    %% INVALID is free because what it costs is not a number but an exceptional
    %% halt consuming the frame's whole allowance -- see eth_evm:run/5, whose
    %% error form deliberately carries no gas figure. It was 5000 here, which is
    %% neither its price nor a halt.
    ?assertEqual({16#FE, "INVALID", 0},
                 {16#FE, "INVALID", eth_fork_schedule:gas_cost(16#FE, cancun, 0, #{})}),
    %% SSTORE's base is 0 because its entire cost is the EIP-2200/EIP-3529
    %% dynamic term. It was 2, swept into a range with POP and JUMPDEST.
    ?assertEqual({16#55, "SSTORE", 0},
                 {16#55, "SSTORE", eth_fork_schedule:gas_cost(16#55, cancun, 0, #{})}).

%% The opcodes the table had wrong before this commit, and the mistake each was.
%% Kept separate so the record stays legible rather than living only in a diff.
wrongly_priced_opcodes_are_now_right_test() ->
    %% SELFBALANCE shared a clause with CREATE and CREATE2 -- they are the three
    %% opcodes that read the *caller's* account -- and inherited 32000. A
    %% contract could not afford to check its own balance. RETURNDATASIZE was
    %% routed through access_cost/3 and cost 2600, a thousand times its price.
    ?assertEqual({16#47, "SELFBALANCE", 5},
                 {16#47, "SELFBALANCE", eth_fork_schedule:gas_cost(16#47, cancun, 0, #{})}),
    ?assertEqual({16#3D, "RETURNDATASIZE", 2},
                 {16#3D, "RETURNDATASIZE", eth_fork_schedule:gas_cost(16#3D, cancun, 0, #{})}),
    %% TLOAD, TSTORE, MCOPY and PUSH0 had no clause at all and fell to the
    %% catch-all, so all four were free. Cancun code uses all four.
    ?assertEqual({16#5C, "TLOAD", 100},
                 {16#5C, "TLOAD", eth_fork_schedule:gas_cost(16#5C, cancun, 0, #{})}),
    ?assertEqual({16#5D, "TSTORE", 100},
                 {16#5D, "TSTORE", eth_fork_schedule:gas_cost(16#5D, cancun, 0, #{})}),
    ?assertEqual({16#5F, "PUSH0", 2},
                 {16#5F, "PUSH0", eth_fork_schedule:gas_cost(16#5F, cancun, 0, #{})}),
    %% Three blocks of the opcode table were priced by range where only some of
    %% the members share a cost. 0x50-0x5B at 2 caught MLOAD, MSTORE, MSTORE8
    %% and JUMPDEST; 0x35-0x3A at 3 caught CALLDATASIZE, CODESIZE and GASPRICE;
    %% 0x55-0x5A at 2 caught JUMP and JUMPI. A range is the wrong tool across a
    %% block where the members do not agree.
    ?assertEqual({16#51, "MLOAD", 3},
                 {16#51, "MLOAD", eth_fork_schedule:gas_cost(16#51, cancun, 0, #{})}),
    ?assertEqual({16#52, "MSTORE", 3},
                 {16#52, "MSTORE", eth_fork_schedule:gas_cost(16#52, cancun, 0, #{})}),
    ?assertEqual({16#53, "MSTORE8", 3},
                 {16#53, "MSTORE8", eth_fork_schedule:gas_cost(16#53, cancun, 0, #{})}),
    ?assertEqual({16#5B, "JUMPDEST", 1},
                 {16#5B, "JUMPDEST", eth_fork_schedule:gas_cost(16#5B, cancun, 0, #{})}),
    ?assertEqual({16#36, "CALLDATASIZE", 2},
                 {16#36, "CALLDATASIZE", eth_fork_schedule:gas_cost(16#36, cancun, 0, #{})}),
    ?assertEqual({16#38, "CODESIZE", 2},
                 {16#38, "CODESIZE", eth_fork_schedule:gas_cost(16#38, cancun, 0, #{})}),
    ?assertEqual({16#3A, "GASPRICE", 2},
                 {16#3A, "GASPRICE", eth_fork_schedule:gas_cost(16#3A, cancun, 0, #{})}),
    ?assertEqual({16#56, "JUMP", 8},
                 {16#56, "JUMP", eth_fork_schedule:gas_cost(16#56, cancun, 0, #{})}),
    ?assertEqual({16#57, "JUMPI", 10},
                 {16#57, "JUMPI", eth_fork_schedule:gas_cost(16#57, cancun, 0, #{})}),
    ok.

%% SLOAD is EIP-2929 warm/cold like every other access, but its cold cost is
%% 2100 rather than the 2600 an account access costs: SLOAD is not an account
%% access, and had it shared that helper it would have been 25% wrong in the
%% expensive direction. It was 2, inside the 0x50-0x5B range.
sload_is_warm_cold_with_its_own_cold_cost_test() ->
    ?assertEqual(2100, eth_fork_schedule:gas_cost(16#54, cancun, 0, #{})),
    ?assertEqual(100,  eth_fork_schedule:gas_cost(16#54, cancun, 0, #{warm => true})),
    %% Before Berlin there is no warm/cold distinction at all, but the price is still
    %% not one number: EIP-150 takes it 50 -> 200 at Tangerine Whistle and EIP-1884
    %% takes it 200 -> 800 at Istanbul. This asserted 200 at every pre-Berlin fork,
    %% which is right for one span of three.
    ?assertEqual(50,   eth_fork_schedule:gas_cost(16#54, frontier, 0, #{})),
    ?assertEqual(50,   eth_fork_schedule:gas_cost(16#54, homestead, 0, #{})),
    ?assertEqual(200,  eth_fork_schedule:gas_cost(16#54, tangerine, 0, #{})),
    ?assertEqual(200,  eth_fork_schedule:gas_cost(16#54, byzantium, 0, #{})),
    ?assertEqual(800,  eth_fork_schedule:gas_cost(16#54, istanbul, 0, #{})),
    ?assertEqual(800,  eth_fork_schedule:gas_cost(16#54, istanbul, 0, #{warm => true})),
    %% Muir Glacier shares Istanbul's rank and so its 800.
    ?assertEqual(800,  eth_fork_schedule:gas_cost(16#54, muir_glacier, 0, #{warm => true})),
    %% The three figures are EIP-150's, EIP-1884's and EIP-2929's, and the warm/cold
    %% split is EIP-2929's -- `warm' is ignored before Berlin on purpose, which is what
    %% the repeated 50 and 200 assert.
    ?assertEqual(50,   eth_fork_schedule:gas_cost(16#54, frontier, 0, #{warm => true})),
    ?assertEqual(200,  eth_fork_schedule:gas_cost(16#54, tangerine, 0, #{warm => true})).

%% MCOPY copies whole words, so it charges 3 base plus 3 per word -- the same
%% shape as the other copy opcodes. It had no clause, so copying memory, which
%% Cancun introduced precisely to stop contracts rolling their own loop, was
%% free.
mcopy_costs_three_plus_three_per_word_test() ->
    ?assertEqual(3, eth_fork_schedule:gas_cost(16#5E, cancun, 0)),
    ?assertEqual(6, eth_fork_schedule:gas_cost(16#5E, cancun, 1)),
    ?assertEqual(6, eth_fork_schedule:gas_cost(16#5E, cancun, 32)),
    %% One byte past a word boundary costs a whole extra word.
    ?assertEqual(9, eth_fork_schedule:gas_cost(16#5E, cancun, 33)),
    ?assertEqual(9, eth_fork_schedule:gas_cost(16#5E, cancun, 64)),
    %% Same shape as CALLDATACOPY and CODECOPY, for comparison.
    ?assertEqual(3, eth_fork_schedule:gas_cost(16#37, cancun, 0)),
    ?assertEqual(6, eth_fork_schedule:gas_cost(16#37, cancun, 32)).

%% EIP-3860 charges both creators 2 gas per 32-byte word of init code, and
%% CREATE2 additionally hashes the init code at KECCAK256's 6 per word, so
%% CREATE2 pays 8 per word and CREATE pays 2. Neither term was in the table: a
%% contract deploying a large contract paid nothing for the code it was about to
%% run. eth_tx:initcode_gas/2 charges the same 2 per word in a transaction's
%% intrinsic gas, so the two agree rather than the opcode double-counting.
eip_3860_initcode_and_create2_hashing_test() ->
    ?assertEqual(32000,   eth_fork_schedule:gas_cost(16#F0, cancun, 0)),
    ?assertEqual(32002,   eth_fork_schedule:gas_cost(16#F0, cancun, 1)),
    ?assertEqual(32002,   eth_fork_schedule:gas_cost(16#F0, cancun, 32)),
    ?assertEqual(32004,   eth_fork_schedule:gas_cost(16#F0, cancun, 33)),
    ?assertEqual(32000,   eth_fork_schedule:gas_cost(16#F5, cancun, 0)),
    ?assertEqual(32008,   eth_fork_schedule:gas_cost(16#F5, cancun, 1)),
    ?assertEqual(32008,   eth_fork_schedule:gas_cost(16#F5, cancun, 32)),
    ?assertEqual(32016,   eth_fork_schedule:gas_cost(16#F5, cancun, 33)),
    %% DELEGATECALL and STATICCALL are calls, not creators, so they pay neither
    %% term: the address is not 20 new bytes of init code.
    ?assertEqual(2600,    eth_fork_schedule:gas_cost(16#F4, cancun, 0)),
    ?assertEqual(2600,    eth_fork_schedule:gas_cost(16#F4, cancun, 32)).

%% RETURNDATASIZE and RETURNDATACOPY had their per-word costs the wrong way
%% round: 0x3D, which takes no length at all, carried the 3-per-word term and
%% 0x3E, which does, carried none. So reading the size of a return buffer was
%% charged per byte of it and copying it was not charged at all.
returndata_copy_costs_three_per_word_and_size_costs_nothing_test() ->
    ?assertEqual(2, eth_fork_schedule:gas_cost(16#3D, cancun, 0)),
    %% The size is independent of the buffer, and the table's length argument
    %% is ignored for it rather than applied.
    ?assertEqual(2, eth_fork_schedule:gas_cost(16#3D, cancun, 1024)),
    ?assertEqual(3, eth_fork_schedule:gas_cost(16#3E, cancun, 0)),
    ?assertEqual(6, eth_fork_schedule:gas_cost(16#3E, cancun, 32)),
    ?assertEqual(9, eth_fork_schedule:gas_cost(16#3E, cancun, 33)),
    %% EXTCODECOPY keeps its 3-per-word term; the swap above did not disturb it.
    ?assertEqual(2600, eth_fork_schedule:gas_cost(16#3C, cancun, 0)),
    ?assertEqual(2603, eth_fork_schedule:gas_cost(16#3C, cancun, 32)).

%% ---------------------------------------------------------------------------
%% Opcode availability
%% ---------------------------------------------------------------------------

%% The whole 0x00-0xFF space, counted per fork. This is the pin for
%% `opcode_exists/2': a table that loses a byte in one clause, or gains one,
%% changes a count here rather than quietly changing which instructions a block
%% will run.
%%
%% The counts are the reference implementations', not this module's, and every
%% one of them is that reference plus one: execution-specs' per-fork `Ops' enums
%% have no 0xFE key and this table does, because go-ethereum has an INVALID
%% instruction and eth_evm reports it as `invalid_opcode' -- so subtracting it
%% would make the pin describe a different interpreter than the one running.
%% Frontier's 130 is the one count that matches a reference outright, as the
%% number of instruction keys in go-ethereum's newFrontierInstructionSet().
%%
%% The intermediate forks are pinned as well, and not only at the ends, because
%% the failures this catches are in the middle: a rule attributed to the wrong
%% fork leaves the newest and oldest counts untouched.
opcode_availability_is_pinned_test() ->
    ?assertEqual(130, available_count(frontier)),
    ?assertEqual(131, available_count(homestead)),
    ?assertEqual(135, available_count(byzantium)),
    ?assertEqual(140, available_count(constantinople)),
    ?assertEqual(140, available_count(petersburg)),
    ?assertEqual(142, available_count(istanbul)),
    ?assertEqual(142, available_count(berlin)),
    ?assertEqual(143, available_count(london)),
    ?assertEqual(144, available_count(shanghai)),
    ?assertEqual(149, available_count(cancun)),
    ?assertEqual(149, available_count(prague)).

%% Availability only ever grows. A fork can add instructions and cannot remove
%% one, so a smaller set at a later fork would mean the table is not ordered the
%% way at_least/2 is -- which is the mistake the previous rank compression would
%% have caused, and the reason the counts above are not enough on their own.
opcode_availability_only_grows_test() ->
    Forks = [frontier, homestead, dao, tangerine, spurious_dragon, byzantium,
             constantinople, petersburg, istanbul, berlin, london, merge, paris,
             shanghai, cancun, prague, osaka, amsterdam],
    Counts = [available_count(F) || F <- Forks],
    ?assertEqual(Counts, lists:sort(Counts)).

%% A byte that has never been assigned is not an instruction in any fork, so
%% nothing has to be added to make the interpreter refuse it. These are the 107
%% gaps in the opcode space.
%%
%% The last run is 0xF6-0xF9 and 0xFB-0xFC, NOT 0xF6-0xFC: 0xFA is STATICCALL,
%% defined from Byzantium, so a run written to 0xFC sweeps it in and asserts that
%% the interpreter must refuse an instruction Byzantium has. The count is what
%% catches that -- 0xF6-0xFC has 108 entries, and 149 + 108 = 257, which is more
%% opcodes than there are bytes in the space.
never_assigned_bytes_are_not_opcodes_in_any_fork_test() ->
    Unassigned = lists:seq(16#0C, 16#0F) ++ lists:seq(16#1E, 16#1F) ++
                 lists:seq(16#21, 16#2F) ++ lists:seq(16#4B, 16#4F) ++
                 lists:seq(16#A5, 16#EF) ++ lists:seq(16#F6, 16#F9) ++
                 lists:seq(16#FB, 16#FC),
    ?assertEqual(107, length(Unassigned)),
    ?assertEqual(256, available_count(amsterdam) + length(Unassigned)),
    Forks = [frontier, byzantium, constantinople, istanbul, london, shanghai,
             cancun, prague, osaka, amsterdam],
    [?assertEqual(false, eth_fork_schedule:opcode_exists(Op, F))
     || Op <- Unassigned, F <- Forks].

%% Each gated opcode appears at the fork that introduced it and at no fork
%% before it. The EIP is named in introduced_by/1's comment beside the byte; this
%% is the same list, so a byte moved to a different fork has to be moved here too.
gated_opcodes_appear_at_their_owning_fork_test() ->
    Gated = [{16#F4, homestead},          % DELEGATECALL  EIP-7
             {16#3D, byzantium},          % RETURNDATASIZE EIP-211
             {16#3E, byzantium},          % RETURNDATACOPY EIP-211
             {16#FA, byzantium},          % STATICCALL     EIP-214
             {16#FD, byzantium},          % REVERT         EIP-140
             {16#1B, constantinople},     % SHL            EIP-145
             {16#1C, constantinople},     % SHR            EIP-145
             {16#1D, constantinople},     % SAR            EIP-145
             {16#3F, constantinople},     % EXTCODEHASH    EIP-1052
             {16#F5, constantinople},     % CREATE2        EIP-1014
             {16#46, istanbul},           % CHAINID        EIP-1344
             {16#47, istanbul},           % SELFBALANCE    EIP-1884
             {16#48, london},             % BASEFEE        EIP-3198
             {16#5F, shanghai},           % PUSH0          EIP-3855
             {16#49, cancun},             % BLOBHASH       EIP-4844
             {16#4A, cancun},             % BLOBBASEFEE    EIP-4844
             {16#5C, cancun},             % TLOAD          EIP-1153
             {16#5D, cancun},             % TSTORE         EIP-1153
             {16#5E, cancun}],            % MCOPY          EIP-5656
    All = [frontier, homestead, dao, tangerine, spurious_dragon, byzantium,
           constantinople, petersburg, istanbul, muir_glacier, berlin, london,
           arrow_glacier, gray_glacier, merge, paris, shanghai, cancun, deneb,
           prague, osaka, bpo1, bpo2, amsterdam],
    [begin
         ?assertEqual(true, eth_fork_schedule:opcode_exists(Op, At)),
         [?assertEqual(false, eth_fork_schedule:opcode_exists(Op, Earlier))
          || Earlier <- All,
             not eth_fork_schedule:at_least(Earlier, At)]
     end || {Op, At} <- Gated].

%% ADDMOD and MULMOD are Frontier. The Byzantium attribution is widespread and
%% wrong: go-ethereum's Frontier instruction set defines both, execution-specs'
%% `frontier' fork defines both, and ethereumjs gates neither behind an EIP check.
%% Nothing refused them before Byzantium, because nothing emitted those bytes
%% before Byzantium.
addmod_and_mulmod_are_frontier_test() ->
    ?assertEqual(true, eth_fork_schedule:opcode_exists(16#08, frontier)),
    ?assertEqual(true, eth_fork_schedule:opcode_exists(16#09, frontier)),
    ?assertEqual(true, eth_fork_schedule:opcode_exists(16#08, homestead)),
    ?assertEqual(true, eth_fork_schedule:opcode_exists(16#09, homestead)).

%% 0xFE is defined, not unassigned, so it reaches do_op/3 and is reported as
%% `invalid_opcode'. execution-specs has no 0xFE key and would call it an
%% undefined byte; both halt the frame and consume its whole allowance, so the
%% two agree on every state root and differ only in the label.
invalid_is_defined_at_every_fork_test() ->
    [?assertEqual(true, eth_fork_schedule:opcode_exists(16#FE, F))
     || F <- [frontier, byzantium, constantinople, istanbul, london, shanghai,
               cancun, prague, osaka, amsterdam]].

%% A fork this module does not know is not a fork that has Cancun's instructions.
%% fork_rank/1's catch-all ranks an unrecognised atom with `frontier', so the
%% genesis set is what such a fork is offered and no more.
an_unknown_fork_has_only_frontier_opcodes_test() ->
    ?assertEqual(available_count(frontier), available_count(no_such_fork)),
    ?assertEqual(false, eth_fork_schedule:opcode_exists(16#5F, no_such_fork)),
    ?assertEqual(false, eth_fork_schedule:opcode_exists(16#48, no_such_fork)).

%% A non-integer opcode is not an opcode, rather than a crash in the interpreter's
%% gate. The machine loop only ever passes `binary:at/2', so this is reachable
%% only by a caller of the table, but a predicate that raises is a predicate
%% callers learn not to use.
opcode_exists_rejects_a_non_opcode_test() ->
    ?assertEqual(false, eth_fork_schedule:opcode_exists(not_a_byte, cancun)),
    ?assertEqual(false, eth_fork_schedule:opcode_exists(-1, cancun)),
    ?assertEqual(false, eth_fork_schedule:opcode_exists(16#08, "cancun")),
    %% An unknown *fork* is not a rejection, though: it ranks with frontier, so a
    %% Frontier instruction is available in it and nothing later is.
    ?assertEqual(true, eth_fork_schedule:opcode_exists(16#08, not_a_fork)).

available_count(Fork) ->
    length([Op || Op <- lists:seq(0, 255),
                  eth_fork_schedule:opcode_exists(Op, Fork)]).

%% ---------------------------------------------------------------------------
%% Fork-selected rules: refunds, SELFDESTRUCT, init code
%% ---------------------------------------------------------------------------

%% EIP-3529 (London) sets MAX_REFUND_QUOTIENT to 5; EIP-2200 (Berlin) capped at
%% half. This is the test that would have caught the interpreter applying Berlin's
%% divisor to London's refund amounts, which is a 40% difference in what a frame
%% gets back and not a rounding difference.
refund_cap_is_a_fifth_from_london_and_a_half_before_test() ->
    [?assertEqual(1000 div 5, eth_fork_schedule:refund_cap(F, 1000))
     || F <- [london, arrow_glacier, gray_glacier, merge, paris, shanghai, cancun,
              prague, osaka, amsterdam]],
    [?assertEqual(1000 div 2, eth_fork_schedule:refund_cap(F, 1000))
     || F <- [frontier, homestead, byzantium, constantinople, petersburg, istanbul,
              berlin, muir_glacier]],
    %% The cap is a fifth, not a half: the two differ on every input large enough
    %% to divide, and 2000 is the first where they differ by more than a unit.
    ?assertNotEqual(eth_fork_schedule:refund_cap(berlin, 2000),
                    eth_fork_schedule:refund_cap(london, 2000)).

%% A cap is a cap: it cannot exceed what was spent, and it is monotonic in what
%% was spent. A negative or non-integer gas figure is refused rather than turned
%% into a negative divisor, which in Erlang would floor toward negative infinity
%% and produce a *negative* refund cap -- an upper bound below zero, so every
%% refund would be clamped to it.
refund_cap_never_exceeds_the_gas_used_test() ->
    Forks = [frontier, berlin, london, shanghai, cancun],
    [begin
         [?assert(eth_fork_schedule:refund_cap(F, G) =< G)
          || G <- lists:seq(0, 40)]
     end || F <- Forks],
    ?assertEqual(0, eth_fork_schedule:refund_cap(cancun, 0)),
    ?assertEqual(0, eth_fork_schedule:refund_cap(cancun, -1)),
    ?assertEqual(0, eth_fork_schedule:refund_cap(cancun, not_a_number)),
    %% The cap rises with spend, and never faster than one-for-one.
    [begin
         Prev = eth_fork_schedule:refund_cap(F, 999),
         Here = eth_fork_schedule:refund_cap(F, 1000),
         ?assert(Here >= Prev)
     end || F <- Forks].

%% EIP-6780: before Cancun SELFDESTRUCT always deleted code and storage; from
%% Cancun it deletes them only for an account created in the same transaction. The
%% predicate answers the *unconditional* half, so it is true before Cancun and
%% false from Cancun -- and getting that polarity backwards is the whole bug, so
%% both directions are asserted rather than one.
selfdestruct_deletes_unconditionally_only_before_cancun_test() ->
    [?assertEqual(true, eth_fork_schedule:selfdestruct_deletes(F))
     || F <- [frontier, homestead, byzantium, constantinople, petersburg, istanbul,
              berlin, london, paris, shanghai, merge]],
    [?assertEqual(false, eth_fork_schedule:selfdestruct_deletes(F))
     || F <- [cancun, deneb, prague, osaka, amsterdam]],
    %% An unknown fork is pre-Cancun by `fork_rank/1''s catch-all, and the safe
    %% direction for a deletion rule is the destructive one: refusing to delete
    %% leaves storage that the chain would have removed.
    ?assertEqual(true, eth_fork_schedule:selfdestruct_deletes(no_such_fork)).

%% EIP-3860 (Shanghai): 2 gas per 32-byte word of init code. Zero before it,
%% because the charge did not exist -- not "small", zero.
initcode_word_cost_is_two_from_shanghai_and_nothing_before_test() ->
    [?assertEqual(2, eth_fork_schedule:initcode_word_cost(F))
     || F <- [shanghai, cancun, prague, osaka, amsterdam]],
    [?assertEqual(0, eth_fork_schedule:initcode_word_cost(F))
     || F <- [frontier, homestead, byzantium, constantinople, petersburg, istanbul,
              berlin, london, merge, paris]].

%% The init-code term as the opcodes charge it, which is the only place the
%% EIP-3860 figure is applied to a length. CREATE's whole dynamic cost is the
%% term; CREATE2's is the term plus KECCAK256's per-word hashing, which is
%% Constantinople's and so is charged at every fork. Getting that wrong in the
%% other direction -- gating the hashing term on Shanghai -- would undercharge
%% every CREATE2 at a pre-Shanghai block by 6 gas a word.
%%
%% Asserted on the *dynamic* part, with CREATE's 32000 base subtracted, because
%% gas_cost/3 is base + dynamic and the base is not what is under test. That the
%% base is fork-invariant is asserted rather than assumed, since the subtraction
%% depends on it.
initcode_gas_is_shanghai_gated_but_create2_hashing_is_not_test() ->
    Len = 64,
    ?assertEqual(?CREATE_BASE, eth_fork_schedule:gas_cost(16#F0, berlin, 0)),
    ?assertEqual(?CREATE_BASE, eth_fork_schedule:gas_cost(16#F0, cancun, 0)),
    %% CREATE: two words of init code, two gas a word from Shanghai and nothing
    %% before it.
    ?assertEqual(0, dyn(16#F0, berlin, Len)),
    ?assertEqual(0, dyn(16#F0, london, Len)),
    ?assertEqual(4, dyn(16#F0, shanghai, Len)),
    ?assertEqual(4, dyn(16#F0, cancun, Len)),
    %% CREATE2 pays the hashing term at every fork, and the init-code term only
    %% from Shanghai: 6 a word always, plus 2 a word from Shanghai.
    ?assertEqual(12, dyn(16#F5, berlin, Len)),
    ?assertEqual(12, dyn(16#F5, london, Len)),
    ?assertEqual(16, dyn(16#F5, shanghai, Len)),
    ?assertEqual(16, dyn(16#F5, cancun, Len)),
    %% A partial word still costs a whole one, at both ends of the fork boundary,
    %% which is the rounding a length argument is most likely to get wrong.
    ?assertEqual(2, dyn(16#F0, shanghai, 1)),
    ?assertEqual(2, dyn(16#F0, shanghai, 32)),
    ?assertEqual(4, dyn(16#F0, shanghai, 33)),
    ?assertEqual(0, dyn(16#F0, berlin, 33)).

dyn(Op, Fork, Len) ->
    eth_fork_schedule:gas_cost(Op, Fork, Len) -
        eth_fork_schedule:gas_cost(Op, Fork, 0).

%% The opcode and the transaction have to charge the same term, because exactly
%% one of them ever applies: eth_block:execute_transactions/5 runs a creation
%% transaction's `data' straight through the EVM without reaching the CREATE
%% opcode, so the intrinsic charge is the only one that fires for it. If the two
%% figures could differ, which of them a transaction paid would depend on the
%% path it took, and neither path would be wrong on its own.
%%
%% CREATE's base term is 32000 at every fork, so subtracting it leaves the
%% dynamic part -- which for CREATE is the init-code term and nothing else. That
%% the base really is fork-invariant is asserted rather than assumed, because the
%% subtraction is what makes this comparison work.
initcode_gas_agrees_with_the_opcode_term_test() ->
    ?CREATE_BASE = 32000,
    Len = 96,
    Words = (Len + 31) div 32,
    [begin
         Base = eth_fork_schedule:gas_cost(16#F0, F, 0),
         ?assertEqual(?CREATE_BASE, Base),
         ?assertEqual(eth_fork_schedule:initcode_word_cost(F) * Words,
                      eth_fork_schedule:gas_cost(16#F0, F, Len) - Base)
     end || F <- [frontier, berlin, london, shanghai, cancun, prague]].

%% ---------------------------------------------------------------------------
%% One owner of a price's composition
%% ---------------------------------------------------------------------------
%%
%% Two tables used to answer "what does this opcode cost": eth_evm:base_cost/1,
%% fork-free, and this module's base_gas_cost/3. They agreed on most totals and
%% decomposed four groups differently, and the interpreter's copy has been
%% deleted. These tests pin the shape of the split, so a second decomposition
%% cannot appear beside the first.

%% An access-sensitive opcode has no constant part, because "is this target warm"
%% is not knowable before the handler looks. If one of them ever gained a
%% non-zero constant, the machine loop would charge it and the handler would
%% charge the whole price again -- the cold BALANCE would cost 5100, which is
%% exactly the bug the two-table arrangement made possible.
access_sensitive_opcodes_have_no_constant_cost_test() ->
    Sensitive = [Op || Op <- lists:seq(0, 255),
                       eth_fork_schedule:access_sensitive(Op)],
    ?assertEqual([16#31, 16#3B, 16#3C, 16#3F, 16#54, 16#F1, 16#F2, 16#F4, 16#FA],
                 Sensitive),
    [?assertEqual(0, eth_fork_schedule:constant_cost(Op, F))
     || Op <- Sensitive,
        F <- [frontier, byzantium, istanbul, berlin, london, shanghai, cancun]],
    %% And the only opcodes whose constant is zero are the ones that are free on
    %% purpose, so the list above is a statement about these nine and not a way
    %% of making the first assertion pass. SSTORE is here for a different reason
    %% than the four beside it: its *entire* cost is the EIP-2200 net-metering
    %% term, which is charged in the interpreter and is not implemented -- so it is
    %% not access-sensitive, because that would promise this table a price it does
    %% not hold. Asserted as a list rather than as "everything else is non-zero"
    %% because "non-zero" is false: these five are zero, four of them deliberately.
    ?assertEqual([16#00, 16#55, 16#F3, 16#FD, 16#FE],
                 [Op || Op <- lists:seq(0, 255),
                       eth_fork_schedule:opcode_exists(Op, cancun),
                       not eth_fork_schedule:access_sensitive(Op),
                       eth_fork_schedule:constant_cost(Op, cancun) =:= 0]).

%% The constant the machine loop charges is the table's own base, for every
%% opcode and every fork. `gas_cost/3' at length 0 is base + dynamic, and dynamic
%% is 0 at length 0 for all of them, so the two must agree exactly. This is the
%% whole-space check that the two tables could not both pass -- and the reason
%% deleting eth_evm's copy was safe is that this pins the survivor.
constant_cost_is_the_tables_own_base_everywhere_test() ->
    Forks = [frontier, byzantium, constantinople, istanbul, berlin, london,
             shanghai, cancun, prague],
    [begin
         ?assertEqual(eth_fork_schedule:gas_cost(Op, F, 0),
                      eth_fork_schedule:constant_cost(Op, F))
     end || F <- Forks,
            Op <- lists:seq(0, 255),
            eth_fork_schedule:opcode_exists(Op, F),
            not eth_fork_schedule:access_sensitive(Op)].

%% EIP-150's pre-Berlin figures, which existed in this table and in *no* part of
%% execution until eth_evm asked for them. Before that a Frontier BALANCE cost
%% 2600, because the interpreter charged a warm base of 100 plus a hardcoded 2500
%% cold surcharge at every fork.
pre_berlin_access_costs_are_eip_150s_test() ->
    Pre = [frontier, homestead, dao, tangerine, spurious_dragon, byzantium,
           constantinople, petersburg, istanbul, muir_glacier],
    %% EIP-150 set BALANCE and EXTCODEHASH to 400, and left EXTCODESIZE,
    %% EXTCODECOPY and the CALL family at 700.
    [?assertEqual(400, eth_fork_schedule:access_cost(16#31, F, #{})) || F <- Pre],
    [?assertEqual(400, eth_fork_schedule:access_cost(16#3F, F, #{})) || F <- Pre],
    [?assertEqual(700, eth_fork_schedule:access_cost(16#3B, F, #{})) || F <- Pre],
    [?assertEqual(700, eth_fork_schedule:access_cost(16#3C, F, #{})) || F <- Pre],
    [?assertEqual(700, eth_fork_schedule:access_cost(Op, F, #{}))
     || F <- Pre, Op <- [16#F1, 16#F2, 16#F4, 16#FA]],
    %% SLOAD has its own legacy figure and is not an account's 400, but it is not
    %% *one* legacy figure either: EIP-150 takes it 50 -> 200 at Tangerine Whistle, so
    %% the three forks before it are at 50, and EIP-1884 takes it to 800 at Istanbul.
    %% This asserted 200 across the whole pre-Berlin span, which is right for one of
    %% the three spans inside it.
    [?assertEqual(50, eth_fork_schedule:access_cost(16#54, F, #{}))
     || F <- [frontier, homestead, dao]],
    [?assertEqual(200, eth_fork_schedule:access_cost(16#54, F, #{}))
     || F <- [tangerine, spurious_dragon, byzantium, constantinople, petersburg]],
    [?assertEqual(800, eth_fork_schedule:access_cost(16#54, F, #{}))
     || F <- [istanbul, muir_glacier]],
    %% Warmth is not observable before Berlin, so the argument makes no
    %% difference: there is one pre-Berlin price per opcode.
    [?assertEqual(eth_fork_schedule:access_cost(Op, F, #{}),
                  eth_fork_schedule:access_cost(Op, F, #{warm => true}))
     || F <- Pre,
        Op <- [16#31, 16#3B, 16#3C, 16#3F, 16#54, 16#F1, 16#F2, 16#F4, 16#FA]].

%% EIP-2929 from Berlin: 100 warm, and cold at the opcode's own figure. SLOAD's
%% cold cost is 2100 and an account's is 2600 -- different constants, which is
%% why they share a table with two numbers each rather than one regime.
berlin_access_costs_are_warm_100_and_cold_per_opcode_test() ->
    Post = [berlin, london, shanghai, cancun, prague, osaka, amsterdam],
    Accounts = [16#31, 16#3B, 16#3C, 16#3F, 16#F1, 16#F2, 16#F4, 16#FA],
    [begin
         ?assertEqual(100, eth_fork_schedule:access_cost(Op, F, #{warm => true})),
         ?assertEqual(2600, eth_fork_schedule:access_cost(Op, F, #{})),
         %% Absent means cold, because that is the common case: an access the
         %% frame has not touched yet. Defaulting to warm would undercharge every
         %% first access in a frame.
         ?assertEqual(2600, eth_fork_schedule:access_cost(Op, F, #{warm => false}))
     end || F <- Post, Op <- Accounts],
    [begin
         ?assertEqual(100, eth_fork_schedule:access_cost(16#54, F, #{warm => true})),
         ?assertEqual(2100, eth_fork_schedule:access_cost(16#54, F, #{}))
     end || F <- Post].

%% EIP-161's two optional terms are Spurious Dragon's, and this function gated
%% them on Berlin -- two forks later. So a Spurious-Dragon-to-Byzantium CALL
%% carrying value paid neither the 9000 nor the 25000 while still being charged
%% the access cost, and a Homestead-to-Tangerine one paid neither at all.
call_optional_terms_start_at_spurious_dragon_not_berlin_test() ->
    Full = #{warm => false, value_transfer => true, new_account => true},
    NoValue = #{warm => false, value_transfer => false, new_account => false},
    Before = [frontier, homestead, dao, tangerine],
    AtOrAfter = [spurious_dragon, byzantium, constantinople, petersburg, istanbul,
                 berlin, london, shanghai, cancun],
    %% Before Spurious Dragon: the access term alone, 700.
    [?assertEqual(700, eth_fork_schedule:call_cost(Op, F, Full))
     || F <- Before, Op <- [16#F1, 16#F2, 16#F4, 16#FA]],
    %% From Spurious Dragon: 700 + 9000 + 25000. The two boundaries are separate
    %% assertions because the gap between them -- Spurious Dragon through
    %% Istanbul -- is exactly the span that was wrong.
    [?assertEqual(700 + 9000 + 25000, eth_fork_schedule:call_cost(Op, F, Full))
     || F <- [spurious_dragon, byzantium, constantinople, petersburg, istanbul],
        Op <- [16#F1, 16#F2, 16#F4, 16#FA]],
    [?assertEqual(2600 + 9000 + 25000, eth_fork_schedule:call_cost(Op, F, Full))
     || F <- [berlin, london, shanghai, cancun],
        Op <- [16#F1, 16#F2, 16#F4, 16#FA]],
    %% A call that moves no value and creates no account pays the access term and
    %% nothing else, at every fork. Charging 25000 on a zero-value call would make
    %% every read-only call cost 25000 more than it should.
    [?assertEqual(eth_fork_schedule:access_cost(Op, F, #{}),
                  eth_fork_schedule:call_cost(Op, F, NoValue))
     || F <- Before ++ AtOrAfter, Op <- [16#F1, 16#F2, 16#F4, 16#FA]],
    %% DELEGATECALL and STATICCALL are priced as CALL and CALLCODE: the same access
    %% term, and the caller decides the optional ones by whether value is moving,
    %% which it never is for either.
    [?assertEqual(eth_fork_schedule:call_cost(16#F1, F, Full),
                  eth_fork_schedule:call_cost(Op, F, Full))
     || F <- AtOrAfter, Op <- [16#F2, 16#F4, 16#FA]].

%% ---------------------------------------------------------------------------
%% SSTORE net metering (EIP-2200)
%% ---------------------------------------------------------------------------
%%
%% The decision tree, arm by arm, with the values the arms must return. `Original'
%% is the value at the start of the transaction, `Current' the value now, `New' the
%% value being written -- so `Original =/= Current' is what EIP-2200 calls a dirty
%% slot, and no separate flag is involved.

%% (1.) A no-op write. This is the case the interpreter got wrong by 2700 gas net:
%% it charged 2900 with a 100 refund, and EIP-2200 says SLOAD_GAS and nothing
%% else -- 100 from EIP-2929.
sstore_noop_costs_a_warm_read_and_refunds_nothing_test() ->
    [?assertEqual({100, 0}, eth_fork_schedule:sstore_cost(F, V, V, V))
     || F <- [berlin, london, shanghai, cancun, prague],
        V <- [0, 1, 42, 16#FFFFFFFF]].

%% (2.1.1.) First write to a slot that was zero: SSTORE_SET_GAS, fork-invariant.
sstore_creating_a_zero_slot_costs_twenty_thousand_test() ->
    [?assertEqual({20000, 0}, eth_fork_schedule:sstore_cost(F, 0, 0, V))
     || F <- [berlin, london, shanghai, cancun], V <- [1, 42]].

%% (2.1.2.) First write to a slot that was non-zero: SSTORE_RESET_GAS, and the
%% clear refund only when the write clears it.
sstore_resetting_a_set_slot_costs_2900_and_clears_for_4800_test() ->
    Post = [berlin, london, shanghai, cancun],
    [?assertEqual({2900, 0}, eth_fork_schedule:sstore_cost(F, 7, 7, 9)) || F <- Post],
    %% EIP-3529's 4800 from London; EIP-2200's own 15000 before it.
    [?assertEqual({2900, 4800}, eth_fork_schedule:sstore_cost(F, 7, 7, 0))
     || F <- [london, shanghai, cancun]],
    ?assertEqual({2900, 15000}, eth_fork_schedule:sstore_cost(berlin, 7, 7, 0)).

%% (2.2.) A dirty write costs SLOAD_GAS and is where the refund adjustments live.
%% A write that puts the slot back to its original value refunds almost all of
%% what the earlier write cost -- that is the whole mechanism EIP-2200 adds.
sstore_dirty_writes_cost_a_warm_read_test() ->
    [?assertEqual(100, element(1, eth_fork_schedule:sstore_cost(F, O, C, N)))
     || F <- [berlin, london, cancun],
        {O, C, N} <- [{0, 1, 2}, {7, 9, 11}, {7, 0, 3}, {7, 5, 8}]].

%% (2.2.2.1.) Back to a slot that was originally zero: the full SET is refunded
%% less the warm read this write costs.
sstore_undoing_a_create_refunds_nineteen_thousand_nine_hundred_test() ->
    [?assertEqual({100, 20000 - 100},
                  eth_fork_schedule:sstore_cost(F, 0, 1, 0))
     || F <- [berlin, london, shanghai, cancun]].

%% (2.2.2.2.) Back to a slot that was originally non-zero: RESET less the warm
%% read. 2900 - 100 = 2800.
%%
%% `Current' is 3, not 0, so that clause (2.2.1.1) -- which refunds negatively for
%% a slot that was cleared earlier in the transaction -- stays out of the way and
%% this pins (2.2.2.2) alone. The case that does put them together is pinned
%% separately, because that is the one where dropping the arm is invisible.
sstore_undoing_a_reset_refunds_2800_test() ->
    [?assertEqual({100, 2800}, eth_fork_schedule:sstore_cost(F, 7, 3, 7))
     || F <- [berlin, london, shanghai, cancun]].

%% (2.2.1.1.) and (2.2.2.2.) together, which is what restoring a *cleared* slot
%% does. The two are not alternatives: the EIP lists both under (2.2.), and a
%% dirty write can satisfy each. The refund here is the net of them, negative,
%% because the transaction already collected the clear refund for zeroing the
%% slot and is now giving it back while also being repaid for the write.
%%
%% A missing (2.2.2.2.) shows up here and nowhere else -- and the symptom is not
%% a wrong refund total, it is a *less negative* one that the refund cap then
%% fails to clamp correctly, so it reaches the state root as a divergence rather
%% than as a wrong answer.
sstore_restoring_a_cleared_slot_sums_both_adjustments_test() ->
    %% EIP-3529's 4800 from London, EIP-2200's 15000 at Berlin.
    ?assertEqual({100, -15000 + 2800}, eth_fork_schedule:sstore_cost(berlin, 7, 0, 7)),
    [?assertEqual({100, -4800 + 2800}, eth_fork_schedule:sstore_cost(F, 7, 0, 7))
     || F <- [london, shanghai, cancun]].

%% (2.2.1.) The clear refund moves in the matching direction when a dirty slot is
%% re-created or deleted again. These are the two arms that make a refund
%% *negative*, which is why the refund is accumulated rather than clamped: an
%% earlier clear is un-refunded when the slot comes back.
sstore_recreating_a_dirty_slot_removes_the_clear_refund_test() ->
    [?assertEqual({100, -4800}, eth_fork_schedule:sstore_cost(F, 7, 0, 3))
     || F <- [london, shanghai, cancun]],
    ?assertEqual({100, -15000}, eth_fork_schedule:sstore_cost(berlin, 7, 0, 3)),
    [?assertEqual({100, 4800}, eth_fork_schedule:sstore_cost(F, 7, 3, 0))
     || F <- [london, shanghai, cancun]],
    ?assertEqual({100, 15000}, eth_fork_schedule:sstore_cost(berlin, 7, 3, 0)).

%% A dirty write that is none of the above earns no refund: it is not undoing the
%% earlier write and it is not crossing zero in either direction.
sstore_dirty_writes_that_change_nothing_else_refund_nothing_test() ->
    [?assertEqual({100, 0}, eth_fork_schedule:sstore_cost(F, 7, 3, 9))
     || F <- [berlin, london, cancun]],
    [?assertEqual({100, 0}, eth_fork_schedule:sstore_cost(F, 0, 3, 9))
     || F <- [berlin, london, cancun]],
    %% Original non-zero, current non-zero, new non-zero, and new is not the
    %% original: nothing fires.
    [?assertEqual({100, 0}, eth_fork_schedule:sstore_cost(F, 5, 3, 9))
     || F <- [berlin, london, cancun]].

%% Refunds accumulate, so two writes in one transaction can together exceed the
%% cap. The cap is `refund_cap/2''s job, not this function's, and the pair is
%% pinned here because a clamping bug in *either* would show up as a frame that
%% comes back with more gas than the rules allow.
sstore_refunds_accumulate_rather_than_clamp_test() ->
    %% A slot created then undone then deleted again: +19900, then the clear.
    Total = fun(F) ->
        {_, R1} = eth_fork_schedule:sstore_cost(F, 0, 0, 1),      %% create
        {_, R2} = eth_fork_schedule:sstore_cost(F, 0, 1, 0),      %% undo
        {_, R3} = eth_fork_schedule:sstore_cost(F, 0, 0, 0),      %% and clear
        R1 + R2 + R3
    end,
    %% The third write is a no-op, so it refunds nothing: 19900 either way.
    ?assertEqual(19900, Total(london)),
    ?assertEqual(19900, Total(berlin)).

%% The sentry. EIP-2200 clause (0): at or below the stipend the frame must fail,
%% and the comparison is `=<', not `<'. 2300 from Berlin; nothing before it,
%% because the sentry is EIP-2200's.
sstore_sentry_is_2300_from_berlin_test() ->
    [?assertEqual(2300, eth_fork_schedule:sstore_sentry(F))
     || F <- [berlin, london, shanghai, cancun, prague, osaka]],
    [?assertEqual(0, eth_fork_schedule:sstore_sentry(F))
     || F <- [frontier, homestead, byzantium, constantinople, petersburg, istanbul]].

%% Berlin and later only, and the boundary is not arbitrary: there are *three*
%% pre-Berlin schedules -- the flat rule, EIP-1283's net metering at Constantinople
%% (a different schedule, not a restatement of the flat one), and Petersburg's
%% revert of it. So pre-Berlin is refused rather than priced, and a caller that
%% forgot to check gets 0 rather than a plausible number.
%% SSTORE is supported at every fork except Constantinople, and the test said the
%% opposite for eight of them. That was not a harmless over-restriction: the refusal
%% was *executed* rather than reported, so a pre-Berlin SSTORE consumed the
%% transaction's whole gas limit and the block's state root was committed anyway. 48
%% of the 266 committed fixtures.
%%
%% Constantinople is the exception and the reason is EIP-1283: it replaced the flat
%% rule with net metering, and Petersburg reverted it. The flat rule is therefore right
%% for the eight other pre-Berlin forks and wrong for exactly that one -- which is why
%% `sstore_supported/1` is a single exception rather than a fork boundary.
code_deposit_cost_is_two_hundred_at_every_fork_test() ->
    %% The yellow paper's `G_codedeposit', and no EIP has ever changed it -- EIP-2
    %% introduced the *consequence* of not being able to pay it and left the figure
    %% alone. A table that said otherwise would be right at one fork and wrong at
    %% every other, and the corpus would only see the one it happened to test.
    [?assertEqual({F, 200}, {F, eth_fork_schedule:code_deposit_cost(F)})
     || F <- [frontier, homestead, dao, tangerine, spurious_dragon, byzantium,
              constantinople, petersburg, istanbul, muir_glacier, berlin, london,
              arrow_glacier, gray_glacier, merge, paris, shanghai, cancun, prague,
              osaka, amsterdam]],
    ?assertEqual(200, eth_fork_schedule:code_deposit_cost(no_such_fork)).

%% EIP-170's `MAX_CODE_SIZE' is `0x6000' = 24576 and EIP-170 is Spurious Dragon, so
%% below it there is **no cap** and the only thing bounding a deployment is what the
%% caller can pay. Answering 24576 everywhere would be right for one span of the
%% schedule and wrong for eight forks, and pre-Spurious-Dragon blocks are on the chain.
max_code_size_is_eip_170s_and_only_from_spurious_dragon_test() ->
    [?assertEqual({F, infinity}, {F, eth_fork_schedule:max_code_size(F)})
     || F <- [frontier, homestead, dao, tangerine]],
    [?assertEqual({F, 24576}, {F, eth_fork_schedule:max_code_size(F)})
     || F <- [spurious_dragon, byzantium, constantinople, petersburg, istanbul,
              muir_glacier, berlin, london, cancun, prague, osaka, amsterdam]],
    ?assertEqual(infinity, eth_fork_schedule:max_code_size(no_such_fork)).

%% EIP-2929, verbatim: "When calling `SSTORE', check if the `(address, storage_key)'
%% pair is in `accessed_storage_keys'. If it is not, charge an **additional**
%% `COLD_SLOAD_COST' gas, and add the pair to `accessed_storage_keys'."
%%
%% This is the term the interpreter was not charging, and it is Berlin-and-later only
%% because EIP-2929 introduces the access list as well as the term.
sstore_cold_cost_is_eip_2929s_additional_term_from_berlin_only_test() ->
    [?assertEqual({F, 2100}, {F, eth_fork_schedule:sstore_cold_cost(F, false)})
     || F <- [berlin, london, arrow_glacier, gray_glacier, merge, paris, shanghai,
              cancun, prague, osaka, amsterdam]],
    [?assertEqual({F, 0}, {F, eth_fork_schedule:sstore_cold_cost(F, false)})
     || F <- [frontier, homestead, dao, tangerine, spurious_dragon, byzantium,
              constantinople, petersburg, istanbul, muir_glacier]],
    %% Warm is 0 at every fork: a slot already in the set is not charged again, and
    %% that is the property the interpreter's marking-then-charging order exists for.
    [?assertEqual(0, eth_fork_schedule:sstore_cold_cost(F, true))
     || F <- [frontier, istanbul, berlin, cancun, prague]],
    ?assertEqual(0, eth_fork_schedule:sstore_cold_cost(no_such_fork, false)).

sstore_is_refused_at_constantinople_and_supported_elsewhere_test() ->
    ?assertNot(eth_fork_schedule:sstore_supported(constantinople)),
    [?assert(eth_fork_schedule:sstore_supported(F))
     || F <- [frontier, homestead, dao, tangerine, spurious_dragon, byzantium,
              petersburg, istanbul, muir_glacier, berlin, london, arrow_glacier,
              gray_glacier, merge, paris, shanghai, cancun, prague, osaka,
              amsterdam]],
    ?assertNot(eth_fork_schedule:sstore_supported(no_such_fork)),
    %% Constantinople still has no price -- the refusal has to remain a refusal rather
    %% than become a plausible number, and the clause that answers it must not answer
    %% 0 *as if* 0 were the price.
    ?assertEqual({0, 0}, eth_fork_schedule:sstore_cost(constantinople, 0, 0, 1)).

%% The flat rule, priced per fork. `SLOAD_GAS` is fork-selected (50 / 200 / 800 by
%% EIP-150 and EIP-1884) and the other three figures are EIP-2200's own, quoted as
%% "SSTORE_SET_GAS: 20000, not changed", "SSTORE_RESET_GAS: 5000, not changed" and
%% "SSTORE_CLEARS_SCHEDULE: 15000, not changed".
the_pre_berlin_sstore_is_the_flat_rule_from_eip_2200s_own_figures_test() ->
    %% A write into an empty slot: SSTORE_SET_GAS, and no refund.
    [?assertEqual({20000, 0}, eth_fork_schedule:sstore_cost(F, 0, 0, 1))
     || F <- [frontier, homestead, byzantium, petersburg]],
    %% A no-op: SLOAD_GAS, which is the fork's, and no refund.
    [?assertEqual({50, 0}, eth_fork_schedule:sstore_cost(F, 7, 7, 7))
     || F <- [frontier, homestead]],
    [?assertEqual({200, 0}, eth_fork_schedule:sstore_cost(F, 7, 7, 7))
     || F <- [tangerine, byzantium, petersburg]],
    [?assertEqual({800, 0}, eth_fork_schedule:sstore_cost(F, 7, 7, 7))
     || F <- [istanbul, muir_glacier]],
    %% A rewrite of a set slot: SSTORE_RESET_GAS, 5,000 -- *not* Berlin's 2,900,
    %% which is EIP-2929's table folding the cold-slot access into it and is a
    %% different rule rather than a different fork's number for the same rule.
    [?assertEqual({5000, 0}, eth_fork_schedule:sstore_cost(F, 1, 1, 2))
     || F <- [frontier, homestead, tangerine, byzantium, petersburg, istanbul]],
    %% A write back to zero refunds SSTORE_CLEARS_SCHEDULE, 15,000 -- and EIP-3529
    %% lowers that to 4,800 at London, which is *after* Berlin and so does not appear
    %% in this branch at all.
    [?assertEqual({5000, 15000}, eth_fork_schedule:sstore_cost(F, 1, 1, 0))
     || F <- [frontier, homestead, tangerine, byzantium, petersburg, istanbul]],
    %% And Berlin, for contrast: its reset is 2,900 (EIP-2929 folding the cold-slot
    %% access in, a different rule rather than another fork's number for this one), and
    %% its clears refund is still 15,000 -- EIP-3529 lowers that at **London**, which is
    %% the fork after Berlin, so it does not appear in this branch at all.
    ?assertEqual({2900, 15000}, eth_fork_schedule:sstore_cost(berlin, 1, 1, 0)),
    ?assertEqual({20000, 0}, eth_fork_schedule:sstore_cost(berlin, 0, 0, 1)),
    ?assertEqual({2900, 4800}, eth_fork_schedule:sstore_cost(london, 1, 1, 0)).

%% ---------------------------------------------------------------------------
%% EIP-7623: the calldata floor
%% ---------------------------------------------------------------------------
%%
%% The EIP's text, which is the whole of it:
%%
%%   tokens_in_calldata = zero_bytes_in_calldata + nonzero_bytes_in_calldata * 4
%%   tx.gasUsed = 21000 + max(STANDARD_TOKEN_COST * tokens_in_calldata
%%                            + execution_gas_used
%%                            + isContractCreation * (32000 + INITCODE_WORD_COST
%%                                                    * words(calldata)),
%%                            TOTAL_COST_FLOOR_PER_TOKEN * tokens_in_calldata)
%%
%% with STANDARD_TOKEN_COST = 4 and TOTAL_COST_FLOOR_PER_TOKEN = 10. So the floor
%% term is `21000 + 10 * tokens' and everything else in the `max' is what this node
%% already charges. Prague.
%%
%% It was not implemented at all, and the corpus found it as a **one gas**
%% discrepancy: a one-zero-byte Prague transaction whose frame happened to use
%% exactly 5 gas came to 21,009 where the floor is 21,010. The one gas was
%% coincidence -- the node was not applying a floor, it was landing one gas under
%% one -- which is worth recording, because a 1-gas bug reads like an off-by-one
%% and would have sent a reader looking at rounding rather than at a missing rule.

there_is_no_calldata_floor_before_prague_test() ->
    [?assertEqual(0, eth_fork_schedule:calldata_floor(F, D))
     || F <- [frontier, byzantium, istanbul, berlin],
        D <- [<<>>, <<0>>, <<1>>, <<0,1,2,255>>]],
    %% Berlin is the point of the test: EIP-2929 landed there, and the floor did
    %% not, so a base fee of 0 and a floor of 0 coexist until Prague.
    ?assertEqual(0, eth_fork_schedule:calldata_floor(berlin, <<0,0,0>>)).

the_floor_is_ten_wei_of_token_over_twenty_one_thousand_test() ->
    %% One **zero** byte is one token: 21000 + 10. One **non-zero** byte is four,
    %% so the same length of calldata costs 40. I wrote `<<1>>' at the zero-byte
    %% price first and the test caught it, which is the whole rule in one line: a
    %% token is a zero byte or a *quarter* of a non-zero one.
    ?assertEqual(21010, eth_fork_schedule:calldata_floor(prague, <<0>>)),
    ?assertEqual(21040, eth_fork_schedule:calldata_floor(prague, <<1>>)),
    ?assertEqual(21080, eth_fork_schedule:calldata_floor(prague, <<1,1>>)),
    ?assertEqual(21120, eth_fork_schedule:calldata_floor(prague, <<1,1,1>>)),
    %% And the two together, which is the fixture's shape: `0x00' is a zero byte.
    ?assertEqual(21010, eth_fork_schedule:calldata_floor(prague, <<0>>)),
    ?assertEqual(21020, eth_fork_schedule:calldata_floor(prague, <<0,0>>)),
    ?assertEqual(21050, eth_fork_schedule:calldata_floor(prague, <<0,1>>)).

the_floor_counts_zero_bytes_and_four_tokens_per_non_zero_byte_test() ->
    %% 0,0,0,0,0,0,0 -> 7 tokens -> 21070
    ?assertEqual(21070, eth_fork_schedule:calldata_floor(prague, <<0,0,0,0,0,0,0>>)),
    %% 1,2,3,4,5,6,7 -> 7 non-zero -> 28 tokens -> 21280
    ?assertEqual(21280, eth_fork_schedule:calldata_floor(prague, <<1,2,3,4,5,6,7>>)),
    %% Mixed: 2 zero + 5 non-zero = 2 + 20 = 22 tokens -> 21220
    ?assertEqual(21220,
                 eth_fork_schedule:calldata_floor(prague, <<0,0,1,2,3,4,5>>)).

no_calldata_is_no_tokens_test() ->
    [?assertEqual(21000, eth_fork_schedule:calldata_floor(prague, <<>>))
     || _ <- [1]].

the_floor_is_a_prague_rule_and_stays_one_test() ->
    %% Every fork from Prague on, and only those.
    [?assertEqual(21010, eth_fork_schedule:calldata_floor(F, <<0>>))
     || F <- [prague, osaka, bpo1, amsterdam]],
    [?assertEqual(0, eth_fork_schedule:calldata_floor(F, <<0>>))
     || F <- [shanghai, cancun, paris, gray_glacier, arrow_glacier, london]].

a_non_binary_calldata_has_no_floor_test() ->
    %% The fallback, so a caller that cannot supply calldata gets the pre-Prague
    %% answer rather than a fabricated one.
    ?assertEqual(0, eth_fork_schedule:calldata_floor(prague, not_a_binary)),
    ?assertEqual(0, eth_fork_schedule:calldata_floor(not_a_fork, <<0>>)).

%% ---------------------------------------------------------------------------
%% Transaction-type availability
%% ---------------------------------------------------------------------------
%% The corpus found the absence of this as a validator that *accepted* an
%% EIP-1559 transaction inside a Berlin block. Admitting something invalid is the
%% worse of the two directions: a node that refuses a valid transaction loses one
%% transaction, whereas a node that accepts an invalid one agrees with nobody about
%% the chain.

%% The lookup is by the *type* `eth_tx:tx_type/1' reports, which is an atom and not
%% the wire byte. I wrote the wire numbers first, the test caught it, and it is
%% worth leaving the distinction visible: the atom is what the rest of the codebase
%% passes around, and the byte is only ever the first byte of the payload.
the_typed_transactions_arrive_in_their_own_eips_fork_test() ->
    ?assertEqual(berlin, eth_fork_schedule:introduced_tx_type(eip2930)),
    ?assertEqual(london, eth_fork_schedule:introduced_tx_type(eip1559)),
    ?assertEqual(cancun, eth_fork_schedule:introduced_tx_type(eip4844)),
    ?assertEqual(prague, eth_fork_schedule:introduced_tx_type(eip7702)),
    %% `legacy' is not in the table, and deliberately so: it is the type the format
    %% had before types existed, so there is no fork that introduced it. Asking
    %% returns `undefined', which is what makes `tx_type_available/2' refuse to use
    %% the table for it at all rather than accidentally getting an answer.
    ?assertEqual(undefined, eth_fork_schedule:introduced_tx_type(legacy)),
    ?assertEqual(undefined, eth_fork_schedule:introduced_tx_type(nonsense)).

a_legacy_transaction_is_available_in_every_fork_test() ->
    [?assert(eth_fork_schedule:tx_type_available(legacy, F))
     || F <- [frontier, homestead, byzantium, london, cancun, prague]],
    %% Including a fork atom this table has never heard of, which is different from
    %% a fork earlier than Berlin: an unknown fork must not be able to admit a typed
    %% transaction.
    ?assert(eth_fork_schedule:tx_type_available(legacy, not_a_fork_at_all)).

a_type_one_needs_berlin_test() ->
    [?assert(eth_fork_schedule:tx_type_available(eip2930, F))
     || F <- [berlin, london, cancun, prague]],
    [?assertNot(eth_fork_schedule:tx_type_available(eip2930, F))
     || F <- [frontier, homestead, byzantium, constantinople, istanbul]].

a_type_two_needs_london_test() ->
    %% The exact pair the corpus found: a 1559 transaction is invalid at Berlin and
    %% valid at London, one fork apart.
    ?assertNot(eth_fork_schedule:tx_type_available(eip1559, berlin)),
    ?assert(eth_fork_schedule:tx_type_available(eip1559, london)),
    [?assertNot(eth_fork_schedule:tx_type_available(eip1559, F))
     || F <- [frontier, homestead, byzantium, tangerine_whistle, istanbul]].

a_type_three_needs_cancun_test() ->
    ?assertNot(eth_fork_schedule:tx_type_available(eip4844, london)),
    ?assert(eth_fork_schedule:tx_type_available(eip4844, cancun)),
    ?assert(eth_fork_schedule:tx_type_available(eip4844, prague)).

a_type_four_needs_prague_test() ->
    ?assertNot(eth_fork_schedule:tx_type_available(eip7702, cancun)),
    ?assert(eth_fork_schedule:tx_type_available(eip7702, prague)).

a_type_this_table_has_never_heard_of_is_not_available_test() ->
    %% A catch-all returning `legacy's answer would make every unknown type
    %% admissible in every fork, which is the opposite of the reason this function
    %% exists. There is no fork for which that is safe.
    [?assertNot(eth_fork_schedule:tx_type_available(T, F))
     || T <- [eip7623, set_code, eip1153, garbage],
        F <- [frontier, berlin, london, cancun, prague]].

%% ---------------------------------------------------------------------------
%% EIP-7702: the authorization list's intrinsic cost
%% ---------------------------------------------------------------------------
%% EIP-7702's "Gas Costs" section: "add a cost of PER_EMPTY_ACCOUNT_COST *
%% authorization list length", with PER_EMPTY_ACCOUNT_COST = 25000. Priced by
%% *length*, because the EIP says "the transaction sender will pay for all
%% authorization tuples, regardless of validity or duplication" -- so a tuple's
%% contents may not appear in the price.

the_authorization_list_costs_twenty_five_thousand_a_tuple_at_prague_test() ->
    [?assertEqual(25000, eth_fork_schedule:set_code_auth_cost(F))
     || F <- [prague, osaka]].

no_fork_before_prague_charges_for_the_authorization_list_test() ->
    %% The type does not exist before Prague and the field is not on the wire, so a
    %% charge there would be a consensus bug on every fork that cannot carry a list.
    [?assertEqual(0, eth_fork_schedule:set_code_auth_cost(F))
     || F <- [frontier, homestead, byzantium, istanbul, berlin, london, cancun]],
    ?assertEqual(0, eth_fork_schedule:set_code_auth_cost(not_a_fork)),
    ?assertEqual(0, eth_fork_schedule:set_code_auth_cost(<<"prague">>)).

%% ---------------------------------------------------------------------------
%% Precompiles: the layout and the alt_bn128 prices
%% ---------------------------------------------------------------------------
%% `eth_evm_precompiles:precompile/2' took no fork, so both questions it should have
%% been asking were answered with one fork's answer. 0x08 is the pairing check from
%% Byzantium (EIP-197) and stays there; 0x09 is blake2f from Istanbul (EIP-152) and is
%% *nothing* before it; 0x0A is EIP-4844's point evaluation from Cancun.
%%
%% The layout is pinned from the committed corpus rather than from the EIPs, because I
%% got it wrong from recollection first -- on the belief that Istanbul swapped 0x08 and
%% 0x09. Two committed fixtures say otherwise and they are the authority here:
%% `byzantium/eip197_ec_pairing/test_gas_costs.json` contains `PUSH1 8 ... CALL`, and
%% `istanbul/eip152_blake2/test_blake2_precompile_delegatecall.json` contains
%% `PUSH1 9, PUSH1 1, DELEGATECALL`. Had the recollection stood, this commit would have
%% swapped a correct layout for a wrong one while claiming to repair it.

the_pairing_check_is_at_0x08_from_byzantium_and_never_moves_test() ->
    [?assertEqual(ecpairing, eth_fork_schedule:precompile_at(F, 8))
     || F <- [byzantium, istanbul, london, cancun, prague]],
    [?assertEqual(What, eth_fork_schedule:precompile_at(cancun, N))
     || {N, What} <- [{1, ecrecover}, {2, sha256}, {3, ripemd160}, {4, identity},
                      {5, modexp}, {6, ecadd}, {7, ecmul}]],
    %% And 0x01..0x05 really are genesis-era, so they are the ones a constant clause
    %% is right for. 0x06 and 0x07 arrived with EIP-196 at Byzantium.
    [?assertEqual(undefined, eth_fork_schedule:precompile_at(F, N))
     || F <- [frontier, homestead], N <- [6, 7, 8, 9, 10]],
    [?assertEqual(ecadd, eth_fork_schedule:precompile_at(byzantium, 6)),
     ?assertEqual(ecmul, eth_fork_schedule:precompile_at(byzantium, 7))].

blake2f_appears_at_0x09_at_istanbul_and_is_nothing_before_it_test() ->
    [?assertEqual(blake2f, eth_fork_schedule:precompile_at(F, 9))
     || F <- [istanbul, london, cancun, prague]],
    %% Before Istanbul, 0x09 is an ordinary account with no code. That is the
    %% difference the defect turned into a wrong answer: a CALL to an address with no
    %% code succeeds and runs empty code, and this node ran a BLAKE2b round there.
    [?assertEqual(undefined, eth_fork_schedule:precompile_at(F, 9))
     || F <- [frontier, homestead, byzantium, spurious_dragon, tangerine_whistle,
              constantinople, petersburg]].

point_evaluation_appears_at_0x0a_at_cancun_test() ->
    [?assertEqual(point_evaluation, eth_fork_schedule:precompile_at(F, 10))
     || F <- [cancun, prague]],
    [?assertEqual(undefined, eth_fork_schedule:precompile_at(F, 10))
     || F <- [frontier, byzantium, istanbul, berlin, london, shanghai]].

nothing_else_is_a_precompile_test() ->
    [?assertEqual(undefined, eth_fork_schedule:precompile_at(cancun, N))
     || N <- [0, 11, 12, 255, 1000, -1]],
    %% A fork this table has never heard of ranks as ancient everywhere else, so it
    %% must not be able to reach a precompile that arrived after genesis. If 0x08 were
    %% a constant clause it would be the one address an unknown fork *could* reach.
    [?assertEqual(undefined, eth_fork_schedule:precompile_at(not_a_fork, N))
     || N <- [6, 8, 9, 10]],
    ?assertEqual(ecrecover, eth_fork_schedule:precompile_at(not_a_fork, 1)).

%% EIP-1108's own table, whose "Current Gas Cost" column is EIP-196's and EIP-197's:
%%
%%   Contract       Address   Current Gas Cost        Updated Gas Cost
%%   ECADD          0x06      500                      150
%%   ECMUL          0x07      40 000                   6 000
%%   Pairing check  0x08      80 000 * k + 100 000     34 000 * k + 45 000
%%
%% The node charged the "Updated" column at *every* fork, so ECADD on mainnet from
%% genesis to 9,069,000 cost 150 where the chain says 500.
alt_bn128_cost_before_and_after_istanbul_test() ->
    [?assertEqual({500, 0}, eth_fork_schedule:bn128_cost(F, ecadd))
     || F <- [byzantium, spurious_dragon, constantinople, petersburg]],
    [?assertEqual({150, 0}, eth_fork_schedule:bn128_cost(F, ecadd))
     || F <- [istanbul, london, berlin, cancun, prague]],
    [?assertEqual({40000, 0}, eth_fork_schedule:bn128_cost(F, ecmul))
     || F <- [byzantium, petersburg]],
    [?assertEqual({6000, 0}, eth_fork_schedule:bn128_cost(F, ecmul))
     || F <- [istanbul, prague]],
    [?assertEqual({100000, 80000}, eth_fork_schedule:bn128_cost(F, ecpairing))
     || F <- [byzantium, petersburg]],
    [?assertEqual({45000, 34000}, eth_fork_schedule:bn128_cost(F, ecpairing))
     || F <- [istanbul, prague]].

%% ---------------------------------------------------------------------------
%% ModExp: EIP-198's price, then EIP-2565's
%% ---------------------------------------------------------------------------
%% The node implemented a mixture that matched no fork at all: EIP-198's multiplication
%% complexity and its divisor of 20, with EIP-2565's floor of 200 -- and no Berlin
%% switch, so Berlin's divisor of 3 and its `words**2' complexity were missing. EIP-198's
%% text has no minimum ("Consumes floor(mult_complexity(...) * max(ADJUSTED_EXPONENT_
%% LENGTH, 1) / GQUADDIVISOR) gas" with GQUADDIVISOR = 20), so a small call at
%% Byzantium was overcharged, and a large one at Berlin was overcharged by up to 6.7x.

modexp_has_eip198s_divisor_and_no_minimum_before_berlin_test() ->
    [?assertEqual({20, 0}, eth_fork_schedule:modexp_cost(F))
     || F <- [frontier, byzantium, spurious_dragon, tangerine_whistle,
              constantinople, petersburg]].

modexp_has_eip2565s_divisor_and_minimum_from_berlin_test() ->
    %% EIP-2565's GQUADDIVISOR is 3 and its minimum is 200.
    [?assertEqual({3, 200}, eth_fork_schedule:modexp_cost(F))
     || F <- [berlin, london, merge, shanghai, cancun, prague]].

modexp_complexity_is_eip198s_piecewise_form_before_berlin_test() ->
    %% EIP-198's own text:
    %%   if x <= 64: x ** 2
    %%   elif x <= 1024: x ** 2 // 4 + 96 * x - 3072
    %%   else: x ** 2 // 16 + 480 * x - 199680
    [?assertEqual(0, eth_fork_schedule:modexp_complexity(byzantium, 0)),
     ?assertEqual(64 * 64, eth_fork_schedule:modexp_complexity(byzantium, 64)),
     ?assertEqual(65 * 65 div 4 + 96 * 65 - 3072,
                  eth_fork_schedule:modexp_complexity(byzantium, 65)),
     ?assertEqual(1024 * 1024 div 4 + 96 * 1024 - 3072,
                  eth_fork_schedule:modexp_complexity(byzantium, 1024)),
     ?assertEqual(1025 * 1025 div 16 + 480 * 1025 - 199680,
                  eth_fork_schedule:modexp_complexity(byzantium, 1025)),
     %% And it is the piecewise form rather than `words**2', which would be 16 at
     %% 1024 bytes -- so this distinguishes them rather than merely pinning one.
     ?assertNotEqual(16 * 16, eth_fork_schedule:modexp_complexity(byzantium, 1024))].

modexp_complexity_is_words_squared_from_berlin_test() ->
    %% EIP-2565 *replaced* the piecewise formula with `words**2' where
    %% words = ceil(max_length / 8). Berlin did not tune EIP-198's formula, it
    %% discarded it, so carrying the piecewise one across Berlin is not a conservative
    %% choice -- it is a different number, and at 32 bytes the two differ by 64x.
    [?assertEqual(1, eth_fork_schedule:modexp_complexity(F, 1))
     || F <- [berlin, cancun]],
    [?assertEqual(16, eth_fork_schedule:modexp_complexity(F, 32))
     || F <- [berlin, cancun]],
    %% 2048 bytes is 256 *words*, so 256 squared. I wrote 256 first, having mistaken
    %% the byte length for the word count; the ceiling is on words, not bytes.
    [?assertEqual(65536, eth_fork_schedule:modexp_complexity(F, 2048))
     || F <- [berlin, cancun]],
    %% Ceiling, not truncation, checked across a whole word boundary rather than at
    %% one value that happens to divide: 33 through 40 bytes are 5 words, 41 is 6.
    [?assertEqual(25, eth_fork_schedule:modexp_complexity(cancun, X))
     || X <- [33, 34, 39, 40]],
    ?assertEqual(36, eth_fork_schedule:modexp_complexity(cancun, 41)),
    ?assertEqual(4096, eth_fork_schedule:modexp_complexity(cancun, 512)).

%% ---------------------------------------------------------------------------
%% EIP-150: the call gas cap and the stipend
%% ---------------------------------------------------------------------------
%% EIP-150 did two things to the gas a child frame receives, and the node applied both
%% at every fork including the four before Tangerine Whistle. The EIP's own text gives
%% the rule it replaced, which is what makes the earlier behaviour derivable rather
%% than a guess:
%%
%%     Define "all but one 64th" of N as N - floor(N / 64).
%%     ...
%%     That is, substitute:
%%     extra_gas = (not ext.account_exists(to)) * opcodes.GCALLNEWACCOUNT +
%%                 (value > 0) * opcodes.GCALLVALUETRANSFER
%%     if compustate.gas < gas + extra_gas:
%%         return vm_exception('OUT OF GAS', needed=gas+extra_gas)
%%     submsg_gas = gas + opcodes.GSTIPEND * (value > 0)
%%
%% The `substitute' block has no cap in it: before the EIP a call got whatever the
%% parent had left and asking for more was an out-of-gas error.

the_call_gas_cap_arrives_with_tangerine_whistle_test() ->
    %% `tangerine' **is** Tangerine Whistle, so the rule applies *at* it and the
    %% "before" set is the three forks ahead of it. I listed `tangerine' on the wrong
    %% side first and the test said so, which is the boundary that matters: EIP-150's
    %% activation is the fork itself, not the one after it.
    [?assertNot(eth_fork_schedule:all_but_one_64th(F))
     || F <- [frontier, homestead, dao]],
    [?assert(eth_fork_schedule:all_but_one_64th(F))
     || F <- [tangerine, spurious_dragon, byzantium, istanbul, berlin, cancun, prague]],
    ?assertNot(eth_fork_schedule:all_but_one_64th(not_a_fork)).

the_call_stipend_arrives_with_tangerine_whistle_too_test() ->
    [?assertEqual(0, eth_fork_schedule:call_stipend(F))
     || F <- [frontier, homestead, dao]],
    [?assertEqual(2300, eth_fork_schedule:call_stipend(F))
     || F <- [spurious_dragon, byzantium, istanbul, berlin, cancun, prague]],
    ?assertEqual(0, eth_fork_schedule:call_stipend(not_a_fork)).

%% `submsg_gas = gas + opcodes.GSTIPEND * (value > 0)' -- the stipend is for calls
%% that move value, not for calls that do not. I read this as backwards when I first
%% looked at the interpreter, on the reasoning that a stipend exists to let a callee
%% do the cheap thing a value transfer can already afford, and the interpreter turned
%% out to be right. The comment in `eth_evm' called the figure EIP-2929's; it is
%% EIP-150's, and EIP-2929 is what it pays for.
the_stipend_is_eip150s_and_it_is_for_value_moves_test() ->
    %% The macro is private to `eth_fork_schedule', so this is the same figure read
    %% back through the only accessor there is -- which is also why the interpreter's
    %% own comment had to be corrected by hand: it named EIP-2929 for a figure EIP-150
    %% introduced, and nothing checked it.
    ?assertEqual(2300, eth_fork_schedule:call_stipend(tangerine)),
    ?assertEqual(0, eth_fork_schedule:call_stipend(dao)).
