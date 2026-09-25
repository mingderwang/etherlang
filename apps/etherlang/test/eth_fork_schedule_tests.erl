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

%% The empty withdrawals root is the SSZ hash_tree_root of an empty list. It is
%% a different value from the MPT empty root, so a block must not reuse it.
empty_withdrawals_root_is_ssz_test() ->
    R = eth_fork_schedule:withdrawals_root([]),
    ?assertEqual(32, byte_size(R)),
    EmptyMpt = eth_trie:root([]),
    ?assertNotEqual(EmptyMpt, R).

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
