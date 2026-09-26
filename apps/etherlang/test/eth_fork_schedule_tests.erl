-module(eth_fork_schedule_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GWEI, 1000000000).
-define(MAINNET_GAS_LIMIT, 30000000).
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
    %% Before Berlin it was a flat 200, raised by EIP-150, with no warm/cold
    %% distinction to honour.
    ?assertEqual(200,  eth_fork_schedule:gas_cost(16#54, istanbul, 0, #{})),
    ?assertEqual(200,  eth_fork_schedule:gas_cost(16#54, istanbul, 0, #{warm => true})).

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
