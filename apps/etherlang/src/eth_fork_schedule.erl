%% Fork-dependent execution rules used by the block builder and EVM.
%%
%% This module is deliberately stateless.  A fork schedule is consensus
%% configuration, not process state, and keeping these helpers pure makes it
%% possible to use them while validating a payload before any worker is
%% started.

-module(eth_fork_schedule).

-export([ blob_gas_per_blob/0, blob_schedule/1, target_blob_gas_per_block/1,
          max_blob_gas_per_block/1, excess_blob_gas/4, blob_base_fee/4,
          blob_gas_price/2,
          past_modelled_range/3,
          past_modelled_range/4,
          current_fork/3,
          current_fork/4,
          fork_schedule/1,
          fork_at/3,
          configured_network/0,
          network_of/1,
          validate_network/1,
          chain_id/0,
          chain_id/1,
          configured_fork/0,
          fork_of/1,
          validate_fork/1,
          at_least/2,
          opcode_exists/2,
          base_fee/2,
          base_fee/3,
          base_fee_delta/2,
          burn_base_fee/2,
          fake_exponential/3,
          process_withdrawals/2,
          make_withdrawal/3,
          exp_byte_cost/1,
          withdrawals_root/1,
          max_withdrawals_per_payload/0,
          apply_withdrawals/1,
          add_beacon_root/2,
          get_beacon_root/1,
          add_beacon_root_to_state/2,
          get_beacon_root_from_state/1,
          beacon_root_contract/0,
          system_address/0,
          beacon_root_slots/1,
          history_buffer_length/0,
          store_beacon_root/3,
          read_beacon_root/2,
          process_beacon_roots/4,
          history_storage_address/0,
          history_serve_window/0,
          history_slot/1,
          store_parent_hash/3,
          read_parent_hash/3,
          process_history/4,
          apply_withdrawals_to_state/2,
          gas_cost/3,
          gas_cost/4,
          constant_cost/2,
          access_sensitive/1,
          access_cost/3,
          call_cost/3,
          refund_cap/2,
          selfdestruct_access_cost/2,
          selfdestruct_deletes/1,
          sstore_cost/4,
          sstore_sentry/1,
          sstore_supported/1,
          initcode_word_cost/1,
          calldata_floor/2,
          tx_type_available/2,
          introduced_tx_type/1,
          set_code_auth_cost/1,
          set_code_refund/1,
          all_but_one_64th/1,
          call_stipend/1,
          sload_gas/1,
          sstore_cold_cost/2,
          code_deposit_cost/1,
          max_code_size/1,
          max_initcode_size/1,
          sender_must_be_eoa/1,
          precompile_addresses/1,
          delegation_resolution_cost/2,
          modexp_cost/1,
          modexp_complexity/2,
          precompile_at/2,
          bn128_cost/2,
          timestamp_in_frame/3,
          timestamp_frame/2,
          activated_at/2 ]).

-define(BASE_FEE_MAX_CHANGE_DENOMINATOR, 8).
%% EIP-7623's TOTAL_COST_FLOOR_PER_TOKEN. Its STANDARD_TOKEN_COST stays 4, which
%% is not restated here because it is already charged by `eth_tx:intrinsic_gas/4'
%% and restating a price in two places is how they drift.
-define(TOTAL_COST_FLOOR_PER_TOKEN, 10).
%% EIP-7702's two authorization costs, **both** of them, and the refund is their
%% difference rather than a third literal.
%%
%% `PER_EMPTY_ACCOUNT_COST` (25,000) is what the *sender* pays per tuple, charged in
%% the intrinsic by `eth_tx:set_code_gas/2' -- for every tuple, "regardless of
%% validity or duplication", so nothing about a tuple's contents may appear in it.
%%
%% `PER_AUTH_BASE_COST` (12,500) is a *processing* cost metered during the state
%% transition, and it is the figure EIP-7702 step 7 subtracts: a delegation by an
%% account that **already exists** is refunded `PER_EMPTY_ACCOUNT_COST -
%% PER_AUTH_BASE_COST`, so the net cost of delegating yourself is half what it is
%% for an account that did not exist. The node did not have it until `v1.66`, and
%% having written the refund as a difference is what keeps the two from drifting:
%% a hand-typed 12,500 next to a 25,000 is two numbers that can disagree.
-define(PER_EMPTY_ACCOUNT_COST, 25000).
-define(PER_AUTH_BASE_COST, 12500).
%% EIP-2565 sets GQUADDIVISOR to 3 and adds a 200 gas minimum; EIP-198 set it to 20
%% and had no minimum. See `modexp_cost/1'.
-define(MOD_EXP_GQUADDIVISOR_BERLIN, 3).
-define(MOD_EXP_MIN_BERLIN, 200).
-define(MOD_EXP_GQUADDIVISOR_BYZANTIUM, 20).
%% The pre-Berlin SSTORE figures, which EIP-2200 quotes as its own "old values ... not
%% changed". See `sstore_cost/4'. Berlin's reset is 2,900, not 5,000, and that is
%% EIP-2929's table rather than a disagreement.
-define(SSTORE_SET_GAS, 20000).
%% EIP-170's MAX_CODE_SIZE, `0x6000` -- the EIP states the parameter in hex and
%% `2**14 + 2**13` is 24576. See `max_code_size/1'.
-define(MAX_CODE_SIZE, 24576).
%% The highest address `precompile_at/2' names. It is a fact about the clauses above
%% it rather than a guess about the protocol, and `precompile_addresses/1' enumerates
%% up to it. See the note on the catch-all clause for why it cannot be exceeded.
-define(HIGHEST_PRECOMPILE, 10).
-define(SSTORE_RESET_GAS, 5000).
%% EIP-150's GSTIPEND. The interpreter's comment called this EIP-2929's; it is not --
%% EIP-2929 prices the callee's first access, and the stipend is what pays for it. The
%% stipend is EIP-150's, from Tangerine Whistle.
-define(CALL_STIPEND, 2300).
%% EIP-2929's COLD_SLOAD_COST. Named because `access_prices/1''s second column is
%% the cold figure and this is the one that is not 2600: an account access is 2600 and a
%% cold *slot* is 2100, and they are different constants rather than different regimes.
-define(COLD_SLOAD_COST, 2100).
-define(BASE_FEE_INITIAL, 1000000000).
%% **EIP-1559 floors the decreasing branch at 0, not at 7 wei.**
%%
%% The reference implementation:
%%
%%     x := parent_base_fee - base_fee_delta
%%     if x < 0 { x = 0 }
%%
%% There is no 7 anywhere in EIP-1559. The floor this module used was carried by
%% `eth_fork_schedule_tests:base_fee_floor_is_seven_wei_test', which argued for it --
%% *"repeatedly applying an empty parent decays geometrically by 7/8, so it takes roughly
%% 140 steps to walk 1 gwei down to the floor"* -- an argument that is internally
%% consistent and rests on a number nobody derived. **A test that asserts a defect and
%% argues for it is worse than no test**, and six of them stood here.
-define(MIN_BASE_FEE, 0).

%% **EIP-1559, quoted:** `ELASTICITY_MULTIPLIER = 2`, and the abstract defines the
%% target as *"block gas limit divided by elasticity multiplier"*. The reference
%% implementation is `parent_gas_limit // ELASTICITY_MULTIPLIER`.
%%
%% **This module used `gas_limit * 2 div 3`**, which is the yellow paper's pre-EIP-1559
%% heuristic rather than EIP-1559's rule. `eth_fork_schedule_tests:base_fee_target_is_two_thirds_test'
%% stated it as the specification and contradicted itself in the same sentence --
%% *"two-thirds of the gas limit, not one-third"*, when the answer is one-half.
-define(ELASTICITY_MULTIPLIER, 2).
%% **Not EIP-4895's, and this constant's provenance is a gap.** EIP-4895 does not
%% name a limit; it says the bound is "enforced by the consensus layer", and the
%% `execution-apis` documents do not state one either. 16 is the figure the
%% networks run, and the comment that used to sit here said "EIP-4895 allows at
%% most 16 withdrawals per payload" -- an attribution no reachable document
%% supports. It is kept because truncating on it is no longer reachable: every
%% caller now refuses a longer list first (see `eth_block:withdrawals_root_of/1'),
%% so this bounds only what a *pure* caller of `withdrawals_root/1' can be handed.
%% Recorded rather than derived, per AGENTS.md §4.2.
-define(MAX_WITHDRAWALS_PER_PAYLOAD, 16).
-define(BEACON_ROOTS_ADDRESS,
        <<16#00, 16#0F, 16#3d, 16#f6, 16#D7, 16#32, 16#80, 16#7E,
          16#f1, 16#31, 16#9f, 16#B7, 16#B8, 16#bB, 16#85, 16#22,
          16#d0, 16#Be, 16#ac, 16#02>>).
%% EIP-4788: the only caller permitted to write the beacon-roots ring buffers,
%% 0xfffffffffffffffffffffffffffffffffffffffe.
%%
%% Written as a value rather than as `<<255:152, 16#fe>>' because an integer
%% bitstring segment is padded on the *left* with zeros: `<<255:152>>' is
%% 18 zero bytes followed by 0xff, which is 0x0000...00ff, not 0xff...ff. That
%% literal produced the address 0x000000000000000000000000000000000000FFFE, and
%% since the deployed beacon-roots contract's very first instruction is
%% `caller == 0xff..fe', every system call reverted and the ring buffers were
%% never written. The failure was silent by construction: the EIP says a failed
%% system call is to be ignored, so the block still validated.
-define(SYSTEM_ADDRESS, <<((1 bsl 152) - 1):152, 16#fe>>).
-define(HISTORY_BUFFER_LENGTH, 8191).
-define(BEACON_ROOTS_GAS, 30000000).
-define(HISTORY_GAS, 30000000).
%% EIP-2935 HISTORY_STORAGE_ADDRESS, 0x0000F90827F1C53a10cb7A02335B175320002935.
%% Spelled byte by byte for the same reason as ?BEACON_ROOTS_ADDRESS above: an
%% address assembled from a single integer literal is easy to get silently wrong,
%% and this one has to match the contract the network actually deployed.
-define(HISTORY_STORAGE_ADDRESS,
        <<16#00, 16#00, 16#F9, 16#08, 16#27, 16#F1, 16#C5, 16#3a,
          16#10, 16#cb, 16#7A, 16#02, 16#33, 16#5B, 16#17, 16#53,
          16#20, 16#00, 16#29, 16#35>>).

%% ---------------------------------------------------------------------------
%% Fork selection
%% ---------------------------------------------------------------------------

%% Fork selection answers "which execution rules apply to this block", so it
%% has to be driven by the same activation points the rest of the network
%% uses. The schedule below is transcribed from go-ethereum's
%% params/config.go (ChainID 1 and ChainID 11155111) and is exercised by a
%% test that cross-checks it against eth_forkid's EIP-2124 data, so the two
%% cannot drift apart silently.
%%
%% SCOPE -- the Merge is a total-difficulty activation, not a block number or a
%% timestamp, and leaving it out was a real gap rather than a scoping
%% decision. A selector given only (number, timestamp) reports the highest
%% *pre*-Merge fork it can see, so a mainnet block from 15537394 (the Merge) to
%% the Shanghai timestamp came back as gray_glacier: executed under a
%% difficulty bomb that had already been halted, at a difficulty that should
%% have been zero. Silent, and wrong for every post-Merge block before
%% Shanghai.
%%
%% The fix is to write down what the network actually uses. EIP-3675 activates
%% on total difficulty, and TERMINAL_TOTAL_DIFFICULTY is a constant of the
%% network rather than a guess about a block number, so a `{ttd, N, Fork}` entry
%% is data in the same sense `{block, N, Fork}` is. current_fork/4 takes the
%% block's total difficulty and honours it.
%%
%% current_fork/3, which has no total difficulty to offer, keeps the old
%% behaviour and reports the pre-Merge fork. That is the honest direction to
%% fail: an unknown total difficulty must not be read as "the merge happened",
%% or a node would apply PoS rules to a block it has not established is
%% post-Merge. Callers that hold a total difficulty must pass it.
%%
%% ETH_NETWORK selects the network (default sepolia, matching the default
%% upstream). ETH_FORK pins the rules outright and is the escape hatch for
%% private or development networks that are not in the table below.
%%
%% **Both of these used to answer a default for a name they did not recognise, and the
%% two answers were not the same kind of thing.** `ETH_NETWORK` fell back to `sepolia'
%% after a `logger:warning` -- emitted from *here*, so on every one of the thirteen call
%% sites, which is a log line that repeats rather than a report. `ETH_FORK' fell back to
%% `cancun' with nothing at all, from a table of twenty-four names, so `ETH_FORK=shangai'
%% gave a node running Shanghai rules that had never said so.
%%
%% A name is a setting like any other, and the failure is the same one the rest of the
%% configuration had: the operator asked for something, the node is doing something else,
%% and there is no point in the lifecycle at which the difference surfaces. The names
%% stay here -- this is the only list of them -- and the *refusal* is
%% `validate_network/0' and `validate_fork/0', which `eth_config_settings:validate/0'
%% calls and `etherlang_app:start/2' acts on. `network_of/1' and `fork_of/1' are the
%% one place a name becomes an atom; everything below them is a fallback whose only
%% remaining job is to keep a unit test from crashing on a name it made up.

configured_network() ->
    case os:getenv("ETH_NETWORK") of
        false -> sepolia;
        "" -> sepolia;
        Value ->
            case network_of(Value) of
                {ok, Net} -> Net;
                error -> sepolia
            end
    end.

%% `{ok, Network}' or `error`. `error' means this node has no schedule for the name, which
%% is not the same as "not a network": a private network is a legitimate reason to set
%% ETH_FORK, and the answer for one of those is that this node cannot validate it.
%% **Hoodi is here because it is the one public network that stays inside the modelled
%% range.** Measured from go-ethereum's `params/config.go' (fetched 2026-10-04), all three
%% public networks activated Prague in March 2025 and the fork after Prague in October or
%% December 2025, so a node modelling to Prague follows none of them. Of the three, Hoodi is
%% the one whose next fork after the modelled range is **unset**, which is what makes it
%% durable rather than expiring -- Sepolia's next activation is 2026-10-06.
%%
%% Both the name and the chain id are accepted, because an operator who has a Hoodi chain id
%% is as likely to paste `560048' as the word.
network_of(Value) ->
    case string:lowercase(string:trim(Value)) of
        "sepolia" -> {ok, sepolia};
        "mainnet" -> {ok, mainnet};
        "hoodi" -> {ok, hoodi};
        "1" -> {ok, mainnet};
        "11155111" -> {ok, sepolia};
        "560048" -> {ok, hoodi};
        _ -> error
    end.

%% Takes the value rather than reading the environment. A predicate that ignores the
%% argument it was handed and goes and reads one itself is how a test ends up asserting
%% about the ambient environment instead of about the value in front of it.
validate_network(Value) ->
    case string:trim(Value) of
        "" -> ok;
        _ ->
            case network_of(Value) of
                {ok, _} -> ok;
                error ->
                    {error, io_lib:format(
                               "~ts is not a network this node has a fork table for; "
                               "it knows mainnet (1) and sepolia (11155111). Falling back "
                               "to sepolia would silently change the chain id, which is "
                               "part of the signing preimage of every transaction, so a "
                               "typo here is a different node rather than a failed one",
                               [string:trim(Value)])}
            end
    end.

%% The chain id of the configured network, from configuration rather than from a
%% peer. eth_state:chain_id/0 fetches eth_chainId over RPC and caches it, which
%% is fine for a query but not for execution: a state transition that blocks on
%% an HTTP round trip can be stalled, or altered, by whoever answers it, and
%% CHAINID is a constant of the network being executed. The id is also part of
%% the signing preimage of every EIP-155 and typed transaction, so one that moved
%% with the upstream endpoint's mood would change which transactions are valid.
chain_id() ->
    chain_id(configured_network()).

chain_id(mainnet) -> 1;
chain_id(sepolia) -> 11155111;
chain_id(hoodi) -> 560048.

%% An explicit rules pin, used for networks that have no schedule in this
%% module. It is *not* consulted for a known network: silently overriding a
%% real activation point would be how a node ends up applying the wrong fork
%% rules, so ETH_FORK only applies where fork_schedule/1 has no data.
%%
%% **The default is `cancun', and the network default is `sepolia'.** Those are two
%% hand-picked answers that happen to agree -- Cancun is the right fork for Sepolia
%% today -- and a reader should not have to know that to trust the defaults. Nothing
%% derives one from the other, and nothing pins the pair; see
%% `eth_fork_schedule_tests' for the pin.
configured_fork() ->
    case os:getenv("ETH_FORK") of
        false -> cancun;
        "" -> cancun;
        Value ->
            case fork_of(Value) of
                {ok, Fork} -> Fork;
                error -> cancun
            end
    end.

%% `{ok, Fork}' or `error'. The single place a name becomes a fork atom, and the only
%% copy of the twenty-four names -- so `validate_fork/0' below and the fallback above
%% cannot disagree about what is a name.
fork_of(Value) ->
    case string:lowercase(string:trim(Value)) of
        "frontier" -> {ok, frontier};
        "homestead" -> {ok, homestead};
        "dao" -> {ok, dao};
        "tangerine" -> {ok, tangerine};
        "spurious_dragon" -> {ok, spurious_dragon};
        "byzantium" -> {ok, byzantium};
        "constantinople" -> {ok, constantinople};
        "petersburg" -> {ok, petersburg};
        "istanbul" -> {ok, istanbul};
        "muir_glacier" -> {ok, muir_glacier};
        "berlin" -> {ok, berlin};
        "london" -> {ok, london};
        "arrow_glacier" -> {ok, arrow_glacier};
        "gray_glacier" -> {ok, gray_glacier};
        "merge" -> {ok, merge};
        "paris" -> {ok, paris};
        "shanghai" -> {ok, shanghai};
        "cancun" -> {ok, cancun};
        "deneb" -> {ok, deneb};
        "prague" -> {ok, prague};
        "osaka" -> {ok, osaka};
        "bpo1" -> {ok, bpo1};
        "bpo2" -> {ok, bpo2};
        "amsterdam" -> {ok, amsterdam};
        _ -> error
    end.

validate_fork(Value) ->
    case string:trim(Value) of
        "" -> ok;
        _ ->
            case fork_of(Value) of
                {ok, _} -> ok;
                error ->
                    {error, io_lib:format(
                               "~ts is not a fork this node knows the gas schedule for; "
                               "falling back to cancun would run a different set of rules "
                               "with nothing anywhere saying so, which is a node that "
                               "reports valid blocks and rejects them",
                               [string:trim(Value)])}
            end
    end.

%% Activation points, ascending. Block-numbered and timestamped forks are kept
%% apart because a block is subject to a timestamped fork when its *timestamp*
%% reaches the activation, and a block-numbered fork when its *number* does.
fork_schedule(mainnet) ->
    [{block, 1150000, homestead},
     {block, 1920000, dao},
     {block, 2463000, tangerine},
     {block, 2675000, spurious_dragon},
     {block, 4370000, byzantium},
     {block, 7280000, constantinople},
     {block, 7280000, petersburg},
     {block, 9069000, istanbul},
     {block, 9200000, muir_glacier},
     {block, 12244000, berlin},
     {block, 12965000, london},
     {block, 13773000, arrow_glacier},
     {block, 15050000, gray_glacier},
     %% EIP-3675. The Merge is reached by total difficulty, not by a block
     %% number, so this is the activation point the network actually uses and
     %% the only one that distinguishes a pre-Merge block from a post-Merge one.
     %% 58750000000000000000000 is mainnet's TERMINAL_TOTAL_DIFFICULTY: the
     %% block that takes total difficulty to this value is the first PoS block,
     %% and Paris applies to it and everything after.
     {ttd, 58750000000000000000000, paris},
     {time, 1681338455, shanghai},
     {time, 1710338135, cancun},
     {time, 1746612311, prague},
     {time, 1764798551, osaka},
     {time, 1765290071, bpo1},
     {time, 1767747671, bpo2}];
%% Sepolia is a post-Berlin chain: every block-numbered fork from Homestead
%% through London is already active at genesis, which is why its ForkID
%% schedule contains no block fork at all. London at genesis is why Sepolia
%% has a base fee from its first block.
fork_schedule(sepolia) ->
    [{ttd, 0, paris},
     {block, 0, homestead},
     {block, 0, tangerine},
     {block, 0, spurious_dragon},
     {block, 0, byzantium},
     {block, 0, constantinople},
     {block, 0, petersburg},
     {block, 0, istanbul},
     {block, 0, muir_glacier},
     {block, 0, berlin},
     {block, 0, london},
     {time, 1677557088, shanghai},
     {time, 1706655072, cancun},
     {time, 1741159776, prague},
     {time, 1760427360, osaka},
     {time, 1761017184, bpo1},
     {time, 1761607008, bpo2},
     {time, 1791294816, amsterdam}];

%% **Hoodi, from `params.HoodiChainConfig`.** Every pre-Merge fork is at block 0 and the
%% terminal total difficulty is 0, so the chain is post-Merge from genesis -- which is why
%% there is no `{ttd, ...}' entry with a non-zero figure and why Shanghai and Cancun are
%% both at timestamp 0. `MergeNetsplitBlock` is 0 there too, so unlike Sepolia it
%% contributes no block fork to a ForkID.
%%
%% `AmsterdamTime` is nil in the source, so the modelled range ends at BPO2. **That is the
%% reason this network is here**: mainnet also leaves it unset, and Sepolia sets it for
%% 2026-10-06.
fork_schedule(hoodi) ->
    [{ttd, 0, paris},
     {block, 0, homestead},
     {block, 0, tangerine},
     {block, 0, spurious_dragon},
     {block, 0, byzantium},
     {block, 0, constantinople},
     {block, 0, petersburg},
     {block, 0, istanbul},
     {block, 0, muir_glacier},
     {block, 0, berlin},
     {block, 0, london},
     {time, 0, shanghai},
     {time, 0, cancun},
     {time, 1742999832, prague},
     {time, 1761677592, osaka},
     {time, 1762365720, bpo1},
     {time, 1762955544, bpo2}];

fork_schedule(_Other) ->
    [].

%% The fork whose rules apply to (BlockNumber, BlockTimestamp) on Network.
%% Returns the highest-ranked active fork; a fork is active when the block's
%% number has reached a block activation or its timestamp has reached a time
%% activation. Paris is the floor, per the scope note above.
current_fork(Network, BlockNumber, BlockTimestamp) ->
    current_fork(Network, BlockNumber, BlockTimestamp, undefined).

%% The total difficulty is what the Merge turns on, so a caller that knows it
%% must say so. `undefined' means "not known", which is treated as "the merge
%% has not been shown to have happened" rather than the other way round: a
%% caller that guessed post-merge would execute a pre-Merge block's uncle
%% header and difficulty bomb under PoS rules and never know it had.
current_fork(Network, BlockNumber, BlockTimestamp, BlockTotalDifficulty)
  when is_integer(BlockNumber), is_integer(BlockTimestamp) ->
    case fork_schedule(Network) of
        [] ->
            %% No schedule for this network, so fall back to the operator's
            %% rules pin rather than guessing from the network name.
            {ok, configured_fork()};
        Schedule ->
            Active = [Fork || {Kind, Point, Fork} <- Schedule,
                               reached(Kind, Point, BlockNumber, BlockTimestamp,
                                       BlockTotalDifficulty)],
            {ok, highest_ranked(Active)}
    end.

%% **Whether a block is past the last fork this node models.**
%%
%% Asked separately from `current_fork/4' because the two answers are different kinds of
%% thing. `current_fork/4' answers a fork for every block and execution proceeds on it; this
%% says whether that answer is a *certification*. A block past the range would be priced and
%% executed under the last modelled fork's rules, which is a wrong figure rather than an
%% absent rule, so a caller that has to certify -- `eth_block_validator' -- declines to.
%%
%% **This is the mechanism that would have caught the Prague decision.** Modelling to Prague
%% makes every public network unusable -- all three activated Prague in March 2025 -- and
%% nothing in the code said so until a test happened to build a block with the wall clock's
%% timestamp. A range question answers it directly, per network, and it is the question to
%% ask before adding a fork rather than after.
%%
%% **Strictly past.** A block at an activation is a block of the fork that activates there,
%% so `Ts =:= Point` is in range. An inclusive comparison would refuse the one block whose
%% rules the node definitely has.
%%
%% **And it expires, which is the point.** Sepolia's modelled range ends at Amsterdam,
%% 2026-10-06. On that day this function starts answering `true' for its head, and that is
%% the correct answer rather than a nuisance: it means the node is one fork behind and says
%% so. Mainnet and Hoodi leave their next fork unset, so neither expires.
past_modelled_range(Network, BlockNumber, BlockTimestamp) ->
    past_modelled_range(Network, BlockNumber, BlockTimestamp, undefined).

past_modelled_range(Network, BlockNumber, BlockTimestamp, BlockTotalDifficulty)
  when is_integer(BlockNumber), is_integer(BlockTimestamp) ->
    case unmodelled_activation(fork_schedule(Network)) of
        none -> false;
        {Kind, Point} -> beyond(Kind, Point, BlockNumber, BlockTimestamp,
                                 BlockTotalDifficulty)
    end.

%% **The frontier is the newest fork this node has NO rules for -- not the newest fork in
%% the schedule.** These are different questions and conflating them is what stopped the
%% node syncing on 2026-10-06.
%%
%% The old form took `last_activation/1' of the network's schedule, which asks "what is
%% the newest fork the chain has", and answered "therefore the node is one fork behind"
%% the moment that fork activated. That is only a valid inference while the node lacks the
%% fork's rules. **Amsterdam's rules are here**: the `slotNumber' header field, the
%% `SLOTNUM' opcode, and EIP-7928's block access list, which changes *no* execution cost
%% -- its own gas table is EIP-2929's warm/cold prices unchanged. So the schedule's last
%% entry is modelled, no schedule has an unmodelled fork, and the honest answer is
%% `false'.
%%
%% **The safety property is not weakened, it is now a test.** With every named fork
%% modelled the runtime check cannot fire, and that is stated rather than hidden.
%% `every_fork_this_module_names_is_modelled_test' and
%% `no_scheduled_fork_is_left_unmodelled_test' assert the relation directly, so a fork
%% added to a schedule without rules fails at the moment it is added -- sooner, and naming
%% the fork, where the old form only moved a frontier.
unmodelled_activation(Schedule) ->
    case [E || E <- Schedule, not lists:member(element(3, E), modelled_forks())] of
        [] -> none;
        Unmodelled -> last_activation(Unmodelled)
    end.

%% **Every fork name this module can resolve.**
%%
%% The first version of this list held six names -- `paris' through `amsterdam' -- and
%% omitted every pre-merge fork and the whole BPO series. **The completeness test written
%% beside it caught that on its first run**: `bpo2' was then the newest *unmodelled*
%% entry, `unmodelled_activation/1' returned it, and the frontier moved *earlier* than
%% before -- the node would have refused everything after BPO2, a strictly larger outage
%% than the one being fixed. **A hand-written list of implemented forks is a second source
%% of truth, and the schedule is not the one to derive it from.**
%%
%% `fork_of/1' is the canonical name list and the two are asserted equal by
%% `every_fork_this_module_names_is_modelled_test', so a name added there without rules
%% fails a test rather than silently shortening the frontier.
modelled_forks() ->
    [homestead, dao, tangerine, spurious_dragon, byzantium, constantinople,
     petersburg, istanbul, muir_glacier, berlin, london, arrow_glacier,
     gray_glacier, merge, paris, shanghai, cancun, deneb, prague, osaka,
     bpo1, bpo2, amsterdam].

reached(block, Point, BlockNumber, _BlockTimestamp, _BlockTotalDifficulty) ->
    BlockNumber >= Point;
reached(time, Point, _BlockNumber, BlockTimestamp, _BlockTotalDifficulty) ->
    BlockTimestamp >= Point;
%% EIP-3675: the block that brings total difficulty to TERMINAL_TOTAL_DIFFICULTY
%% is the first block of the PoS chain. Greater-or-equal, not greater: the
%% transition block is itself post-Merge, and treating it as the last PoW block
%% would put it under both rule sets.
reached(ttd, _Point, _BlockNumber, _BlockTimestamp, undefined) -> false;
reached(ttd, Point, _BlockNumber, _BlockTimestamp, TotalDifficulty)
  when is_integer(TotalDifficulty) ->
    TotalDifficulty >= Point.

%% ---------------------------------------------------------------------------
%% Fork time frames
%% ---------------------------------------------------------------------------
%%
%% The engine API requires `-38005: Unsupported fork' when a payload's timestamp
%% "does not fall within the time frame" of the fork the method serves
%% (execution-apis src/engine/cancun.md, engine_newPayloadV3 item 2,
%% engine_forkchoiceUpdatedV3 item 2.2, engine_getPayloadV3 item 1). This is the
%% whole reason a versioned method exists: newPayloadV3 is the Cancun method, so
%% a Prague timestamp arriving on it means the client sent the wrong version and
%% the answer is an error, not a status.
%%
%% The frame of a timestamped fork F is [activation(F), activation(next)), half
%% open, so the fork that supersedes F owns its own activation instant. Without
%% the half-open upper bound a Cancun payload at exactly the Prague activation
%% time would be accepted by two methods at once.
%%
%% This reads the same schedule as current_fork/4 rather than a second table, so
%% the two cannot disagree about when a fork starts. It is deliberately *not*
%% current_fork/4 with a number supplied: a payload's timestamp can be checked
%% without knowing its block number or its total difficulty, and the -38005 check
%% runs before the payload is decoded far enough to have either.

%% timestamp_frame/2 is exported alongside timestamp_in_frame/3 because the
%% activation instants are what a test needs in order to state the *boundary*
%% cases -- "the last instant in frame", "the first instant out of it" -- and a
%% test that hard-codes those numbers will silently disagree with the schedule
%% when the schedule changes. Reading them from here means eth_fork_schedule_tests
%% pins the *values* and eth_engine_tests pins the *behaviour at* the values, and
%% neither can drift without the other noticing.

-spec timestamp_in_frame(atom(), atom(), integer()) -> boolean().
timestamp_in_frame(Network, Fork, Timestamp) when is_integer(Timestamp) ->
    case timestamp_frame(Network, Fork) of
        {ok, From, infinity} -> Timestamp >= From;
        {ok, From, To} -> Timestamp >= From andalso Timestamp < To;
        error -> false
    end;
timestamp_in_frame(_Network, _Fork, _Timestamp) -> false.

-spec timestamp_frame(atom(), atom()) -> {ok, integer(), integer() | infinity} | error.
timestamp_frame(Network, Fork) ->
    Times = [{Point, Name} || {time, Point, Name} <- fork_schedule(Network)],
    case lists:keyfind(Fork, 2, Times) of
        {From, Fork} ->
            {ok, From, next_time_after(Times, From)};
        false ->
            %% The fork is not timestamp-activated on this network. It may be
            %% block-activated, or absent from the schedule entirely. Either way
            %% there is no time frame to check a timestamp against, and reporting
            %% -38005 for a fork this network does not timestamp would refuse
            %% every payload on a network that predates the fork.
            error
    end.

%% The instant a fork becomes active, or `error' if this network does not
%% timestamp it. This is the *lower* bound only, and it is deliberately not
%% timestamp_in_frame/3: "is the timestamp at or after Shanghai" is a one-sided
%% question, and answering it with a frame makes a post-Cancun timestamp fail it --
%% Shanghai's frame closes when Cancun opens, so every timestamp from Cancun
%% onwards would be reported as "before Shanghai", and newPayloadV2 would then
%% demand the V1 structure of a Cancun payload.
-spec activated_at(atom(), atom()) -> {ok, integer()} | error.
activated_at(Network, Fork) ->
    case timestamp_frame(Network, Fork) of
        {ok, From, _To} -> {ok, From};
        error -> error
    end.

next_time_after(Times, From) ->
    case lists:sort([Point || {Point, _} <- Times, Point > From]) of
        [Next | _] -> Next;
        [] -> infinity
    end.

%% Pick the highest-ranked active fork. Ties are broken towards the fork that
%% appears earliest in the schedule, and the choice is made by explicit filter
%% rather than by relying on the stability of lists:sort/2, because the forks
%% that share a rank are the ones this rule exists to disambiguate. Muir
%% Glacier only delays the difficulty bomb, so it ranks with Istanbul and
%% Istanbul -- the fork that actually introduced the rules -- is reported.
highest_ranked([]) -> paris;
highest_ranked(Forks) ->
    MaxRank = lists:max([fork_rank(F) || F <- Forks]),
    hd([F || F <- Forks, fork_rank(F) =:= MaxRank]).

%% Alias kept for callers that think of the schedule lookup as the primary
%% operation. fork_at/3 is current_fork/3 under a clearer name.
fork_at(Network, BlockNumber, BlockTimestamp) ->
    current_fork(Network, BlockNumber, BlockTimestamp).

%% Ranks must agree with activation order, because highest_ranked/1 resolves
%% two concurrently active forks (a block-numbered one and a timestamped one)
%% purely by rank. Deneb is the pre-release name for Cancun and so shares its
%% rank.
%%
%% Muir Glacier deliberately shares Istanbul's rank, and that is not a
%% compression to be tidied up. Muir Glacier delays the difficulty bomb and
%% changes no execution rule, so the fork a caller must be told about is the one
%% that introduced the rules -- Istanbul. Give Muir Glacier a rank of its own,
%% one higher, and highest_ranked/1 reports `muir_glacier' for every block from
%% 12,244,000 onward: mainnet block 12,243,999 stopped answering `istanbul' and
%% started answering `muir_glacier', which is a name no rule is gated on and no
%% client reports. fork_selection_test pins this.
%%
%% Arrow and Gray Glacier keep ranks of their own, above the fork whose rule they
%% delay, which is what the old ordering did and what their activation points
%% imply.
%%
%% Every other fork gets a rank of its own. The previous ordering collapsed
%% Frontier through Petersburg into a single rank 0, which read as harmless --
%% the only features gated on `at_least/2' were Berlin, London, Shanghai and
%% Cancun, all unaffected by the compression. What it made impossible was gating
%% on anything *earlier*: with byzantium and constantinople both at 0,
%% `at_least(frontier, byzantium)' was true, so a rule introduced by EIP-145 could
%% not be expressed and nothing could refuse an instruction a fork did not have.
%% That is the same gap the interpreter's flat gas schedule came from, and
%% opcode_exists/2 is the first thing to need it fixed.
fork_rank(frontier) -> 0;
fork_rank(homestead) -> 1;
fork_rank(dao) -> 2;
fork_rank(tangerine) -> 3;
fork_rank(spurious_dragon) -> 4;
fork_rank(byzantium) -> 5;
fork_rank(constantinople) -> 6;
fork_rank(petersburg) -> 7;
fork_rank(istanbul) -> 8;
fork_rank(muir_glacier) -> 8;
fork_rank(berlin) -> 9;
fork_rank(london) -> 10;
fork_rank(arrow_glacier) -> 11;
fork_rank(gray_glacier) -> 12;
fork_rank(merge) -> 13;
fork_rank(paris) -> 14;
fork_rank(shanghai) -> 15;
fork_rank(cancun) -> 16;
fork_rank(deneb) -> 16;
fork_rank(prague) -> 17;
fork_rank(osaka) -> 18;
fork_rank(bpo1) -> 19;
fork_rank(bpo2) -> 20;
fork_rank(amsterdam) -> 21;
%% An atom this module does not know ranks with `frontier', which makes
%% at_least(Unknown, Feature) false for every feature that came after genesis
%% and true for none of them -- the safe direction, since a rule wrongly believed
%% inactive is a rule the node declines to apply, and opcode_exists/2 answers
%% false for such a fork rather than admitting Cancun's instructions to it.
fork_rank(_) -> 0.

at_least(Fork, Feature) ->
    fork_rank(Fork) >= fork_rank(Feature).

%% ---------------------------------------------------------------------------
%% Opcode availability
%% ---------------------------------------------------------------------------
%% ---------------------------------------------------------------------------
%% An opcode the executing fork does not have is not a cheap instruction, it is
%% an exceptional halt that consumes the frame's whole gas allowance. That is
%% the difference between a state root and a wrong one, and the interpreter
%% cannot get it from the gas table: a price says what an opcode costs *once it
%% is there*, and says nothing about whether it is there. So availability is its
%% own question with its own answer.
%%
%% The data below is derived, not guessed. Every entry names the fork that
%% introduced the opcode and the EIP that did it, and the whole 0x00-0xFF space
%% is pinned per fork by opcode_availability_is_pinned_test
%% -- so a typo in a single byte here fails a test rather than silently
%% enabling an instruction a fork does not have (or, worse, disabling one it
%% does).
%%
%% Two things are deliberately *not* gated here, because both are false before
%% the fork that introduced them and true after it, rather than absent:
%%
%%   * 0x44 is DIFFICULTY at Frontier and PREVRANDAO from Paris. The byte is
%%     defined in every fork; only its meaning changes, and that is handled
%%     where the value is read, not here.
%%   * 0xFE INVALID is defined from Frontier. It halts, but it is a specified
%%     halt rather than a missing instruction, and eth_evm reports it as
%%     `invalid_opcode' rather than as an undefined byte.
%%
%% Anything `introduced_by/1' does not name is not an opcode in any fork: the 107
%% gaps in the 0x00-0xFF space (0x0C-0x0F, 0x1E-0x1F, 0x21-0x2F, 0x4B-0x4F,
%% 0xA5-0xEF, 0xF6-0xF9, 0xFB-0xFC) have never been assigned. Note that the last
%% run stops short of 0xFC and skips 0xFA: 0xFA is STATICCALL, so a run written
%% 0xF6-0xFC would both sweep in an instruction Byzantium has and make the table
%% claim more opcodes than the space contains. `opcode_exists/2' answers false for
%% the gaps in every fork, so the interpreter halts on them rather than falling
%% through to a cost of 3.
%%
%% The `undefined' clause is load-bearing rather than defensive. `at_least/2'
%% compares ranks, and fork_rank/1's catch-all ranks an unrecognised atom at 0 --
%% the rank of `frontier'. So at_least(cancun, undefined) is *true*, and writing
%% the answer as a bare at_least/2 call would report every unassigned byte in the
%% opcode space as available in every fork.
-spec opcode_exists(integer(), atom()) -> boolean().
opcode_exists(Opcode, Fork) when is_integer(Opcode), is_atom(Fork) ->
    case introduced_by(Opcode) of
        undefined -> false;
        At -> at_least(Fork, At)
    end;
opcode_exists(_Opcode, _Fork) ->
    false.

%% Every opcode, with the fork that introduced it. This is one table rather than
%% a genesis set plus a list of later arrivals because the two are not separable
%% questions: whether a byte is an opcode at all, and which fork introduced it,
%% are one lookup, and splitting them is how the first version of this got it
%% wrong -- it asked the genesis set about the post-genesis arrivals, which by
%% construction are not in it, so 0xFD REVERT and 0x1B SHR were reported missing
%% in every fork and 18 of this module's tests failed.
%%
%% The genesis set is verified, not recalled. It is the yellow paper's appendix
%% H, and it is byte-for-byte the 130 instruction keys of go-ethereum's
%% newFrontierInstructionSet() (core/vm/jump_table.go). The later forks were
%% cross-checked the same way against the `Ops' enums in execution-specs'
%% per-fork vm/instructions/__init__.py, whose counts this reproduces exactly:
%% Byzantium 134, Constantinople 139, Istanbul 141, London 142, Shanghai 143,
%% Cancun 148.
%%
%% Two points where the references differ from each other, or from what is
%% commonly written, and what this table does about it:
%%
%%   * ADDMOD and MULMOD are Frontier, not Byzantium. The Byzantium attribution
%%     is widespread and wrong: go-ethereum's Frontier instruction set defines
%%     both, execution-specs' `frontier' fork's Ops enum defines both, and
%%     ethereumjs gates neither behind an EIP check in its interpreter. No
%%     implementation consulted refuses them before Byzantium, because before
%%     Byzantium no compiler emitted those bytes.
%%   * 0xFE is defined, not unassigned. go-ethereum has an INVALID instruction
%%     and eth_evm reports it as `invalid_opcode'; execution-specs has no 0xFE
%%     key, so there it is an undefined byte. Both halt the frame and consume its
%%     whole allowance, so the two agree on every state root and disagree only on
%%     the label. This table follows go-ethereum, which is the reading that lets
%%     the existing `invalid_opcode' reason keep its meaning.
%%
%% Grouped into the runs that share a contiguous range in the table -- 0x50-0x5B,
%% the stack and storage block; 0x60-0x9F, the three stack-shuffling runs -- and
%% named individually elsewhere, because a range that spans an unassigned byte is
%% how an opcode nobody has assigned ends up looking defined. The upper bound of
%% the first run is 0x5B and not 0x5F for exactly that reason: 0x5C-0x5E are
%% Cancun's transient storage and MCOPY, and 0x5F is Shanghai's PUSH0, so a
%% range to 0x5F would have declared all four to be Frontier.
%%
%%   0x1B SHL / 0x1C SHR / 0x1D SAR  EIP-145  Constantinople
%%   0x3D RETURNDATASIZE            EIP-211  Byzantium
%%   0x3E RETURNDATACOPY            EIP-211  Byzantium
%%   0x3F EXTCODEHASH               EIP-1052 Constantinople
%%   0x46 CHAINID                   EIP-1344 Istanbul
%%   0x47 SELFBALANCE               EIP-1884 Istanbul
%%   0x48 BASEFEE                   EIP-3198 London
%%   0x49 BLOBHASH                  EIP-4844 Cancun
%%   0x4A BLOBBASEFEE               EIP-4844 Cancun
%%   0x4B SLOTNUM                   EIP-7843 Amsterdam
%%   0x5C TLOAD                     EIP-1153 Cancun
%%   0x5D TSTORE                    EIP-1153 Cancun
%%   0x5E MCOPY                     EIP-5656 Cancun
%%   0x5F PUSH0                     EIP-3855 Shanghai
%%   0xF4 DELEGATECALL              EIP-7    Homestead
%%   0xF5 CREATE2                   EIP-1014 Constantinople
%%   0xFA STATICCALL                EIP-214  Byzantium
%%   0xFD REVERT                    EIP-140  Byzantium
introduced_by(Op) when Op >= 16#00, Op =< 16#0B -> frontier;
introduced_by(Op) when Op >= 16#10, Op =< 16#1A -> frontier;
introduced_by(Op) when Op >= 16#30, Op =< 16#3C -> frontier;
introduced_by(Op) when Op >= 16#40, Op =< 16#45 -> frontier;
introduced_by(Op) when Op >= 16#50, Op =< 16#5B -> frontier;
introduced_by(Op) when Op >= 16#60, Op =< 16#9F -> frontier;
introduced_by(Op) when Op >= 16#A0, Op =< 16#A4 -> frontier;
introduced_by(Op) when
      Op =:= 16#20; Op =:= 16#FE; Op =:= 16#FF;
      Op =:= 16#F0; Op =:= 16#F1; Op =:= 16#F2; Op =:= 16#F3 -> frontier;
introduced_by(16#1B) -> constantinople;
introduced_by(16#1C) -> constantinople;
introduced_by(16#1D) -> constantinople;
introduced_by(16#3D) -> byzantium;
introduced_by(16#3E) -> byzantium;
introduced_by(16#3F) -> constantinople;
introduced_by(16#46) -> istanbul;
introduced_by(16#47) -> istanbul;
introduced_by(16#48) -> london;
introduced_by(16#49) -> cancun;
introduced_by(16#4A) -> cancun;
introduced_by(16#4B) -> amsterdam;
introduced_by(16#5C) -> cancun;
introduced_by(16#5D) -> cancun;
introduced_by(16#5E) -> cancun;
introduced_by(16#5F) -> shanghai;
introduced_by(16#F4) -> homestead;
introduced_by(16#F5) -> constantinople;
introduced_by(16#FA) -> byzantium;
introduced_by(16#FD) -> byzantium;
introduced_by(_) -> undefined.

%% ---------------------------------------------------------------------------
%% EIP-1559
%% ---------------------------------------------------------------------------

%% Compute the next block's base fee from its parent.
%%
%% **The target is HALF the parent gas limit**, `gas_limit // ELASTICITY_MULTIPLIER` with
%% `ELASTICITY_MULTIPLIER = 2` -- EIP-1559, and the rule its abstract states in prose:
%% the base fee is a function of the gas used in the parent and the *"gas target (block
%% gas limit divided by elasticity multiplier)"*. This used two thirds.
%%
%% **And the two versions agree on an empty parent**, which is why this survived. With
%% `gas_used = 0` the deviation equals the target exactly, so
%% `parent * delta / target / 8` collapses to `parent / 8` *independently of the target*
%% -- `base_fee(0, 30_000_000, 1 gwei)` is 875,000,000 either way. The two only part
%% company when the parent used between **half** and **two thirds** of its limit, and in
%% that window they do not merely disagree by a factor: one raises the fee where the
%% other lowers it. `eth_fork_schedule_tests:base_fee_full_block_test' now pins both
%% sides of that.
%%
%% The order of operations is EIP-1559's and is not interchangeable with any other:
%% the deviation is applied to the parent fee, divided by the target, then by eight.
%% A non-zero deviation always raises a rising base fee by at least one wei.
base_fee(ParentGasUsed, ParentGasLimit) ->
    base_fee(ParentGasUsed, ParentGasLimit, ?BASE_FEE_INITIAL).

base_fee(_ParentGasUsed, 0, ParentBaseFee) when is_integer(ParentBaseFee) ->
    ParentBaseFee;
base_fee(ParentGasUsed, ParentGasLimit, ParentBaseFee)
  when is_integer(ParentGasUsed), is_integer(ParentGasLimit),
       is_integer(ParentBaseFee), ParentGasLimit > 0 ->
    Target = ParentGasLimit div ?ELASTICITY_MULTIPLIER,
    case Target of
        0 -> ParentBaseFee;
        _ when ParentGasUsed =:= Target -> ParentBaseFee;
        _ when ParentGasUsed > Target ->
            Delta = fee_delta(ParentBaseFee, ParentGasUsed, ParentGasLimit, Target),
            ParentBaseFee + max(1, Delta);
        _ ->
            Delta = fee_delta(ParentBaseFee, ParentGasUsed, ParentGasLimit, Target),
            max(?MIN_BASE_FEE, ParentBaseFee - Delta)
    end.

%% **Fee-independent gas deviation from the target -- a magnitude, not a signed
%% quantity.** The name said "signed" and the code returned `abs': a parent above the
%% target and one equally far below it answer the same number, which is what
%% `base_fee/3` needs but not what "signed" describes. The comment is corrected rather
%% than the code, because the magnitude is right and the word was wrong.
%%
%% This is also the quantity `base_fee/3' applies to the parent fee.
base_fee_delta(ParentGasUsed, ParentGasLimit)
  when is_integer(ParentGasUsed), is_integer(ParentGasLimit), ParentGasLimit > 0 ->
    Target = ParentGasLimit div ?ELASTICITY_MULTIPLIER,
    TargetDelta = case ParentGasUsed > Target of
        true -> ParentGasUsed - Target;
        false -> Target - ParentGasUsed
    end,
    %% The parent fee is applied in base_fee/3.  The public two-argument
    %% helper reports the gas deviation rather than pretending to know it.
    TargetDelta;
base_fee_delta(_GasUsed, _GasLimit) ->
    0.

fee_delta(ParentBaseFee, ParentGasUsed, ParentGasLimit, Target) ->
    TargetDelta = base_fee_delta(ParentGasUsed, ParentGasLimit),
    ParentBaseFee * TargetDelta div Target div ?BASE_FEE_MAX_CHANGE_DENOMINATOR.

burn_base_fee(BaseFee, GasUsed) when is_integer(BaseFee), is_integer(GasUsed) ->
    BaseFee * GasUsed.

%% ---------------------------------------------------------------------------
%% EIP-4844 blob gas
%% ---------------------------------------------------------------------------

%% Blob gas is a separate resource from execution gas: it is metered per blob
%% rather than per operation, it has its own per-block target, and its price
%% moves on its own curve.
%%
%% SCOPE -- these are the Cancun parameters. EIP-7691 (Prague) raises the
%% per-block blob target and adds a per-block cap, so on a network past Prague
%% the excess-blob-gas calculation below is not the one that applies. This
%% client does not model the later blob schedule, and saying so is preferable
%% to silently charging the Cancun curve.
-define(MIN_BLOB_GASPRICE, 1).

%% **EIP-7918's `BLOB_BASE_COST` = `2**13`.** The constant is the *execution gas* a node
%% is assumed to spend per blob, and it is what the reserve price is expressed in: the
%% rule compares the price of `GAS_PER_BLOB` blob gas against `BLOB_BASE_COST` units of
%% execution gas priced at the parent's base fee. It is a **parameter of the comparison,
%% not a charge** -- nothing here bills a transaction this much, and reading it as a cost
%% would put 8,192 gas per blob into a block's `gasUsed`.
-define(BLOB_BASE_COST, 8192).

blob_gas_per_blob() -> 131072.

%% **EIP-4844's per-blob gas never changes, so it is the one blob figure without a
%% fork argument.** Every other figure in this section is a fork parameter, and having
%% exactly one function here that cannot be asked for a fork is what keeps the others
%% honest: a caller that has a fork in hand and calls this one is getting a constant,
%% and a constant is the right answer for this one.

%% **The blob schedule, per fork: `{TargetBlobs, MaxBlobs, UpdateFraction}'.**
%%
%% Source: the `BlobScheduleConfig' of go-ethereum's `params/config.go', fetched
%% 2026-10-05. **Every one of these is a consensus constant read out of the chain
%% configuration**, not derived here, and the table is the whole of it:
%%
%%     fork    target  max  update fraction
%%     Cancun      3    6           3338477
%%     Prague      6    9           5007716
%%     BPO1       10   15           8346193
%%     BPO2       14   21          11684671
%%     BPO3       21   32          20609697
%%     BPO4       14   21          13739630
%%
%% **BPO3 and BPO4 are in the table and not in any activation schedule this node knows.**
%% No network has scheduled them, so they are unreachable, and they are here so that a
%% future activation is a data change rather than a code change. **BPO5 has no entry in
%% the source at all** -- the chain configuration defines `DefaultBPO5BlobConfig' in a
%% different file and no network lists it -- so `bpo5' falls back to BPO4's, which is
%% the wrong answer and is unreachable for the same reason.
%%
%% **Osaka and Amsterdam deliberately have no row.** The source says so: "Named forks such
%% as Osaka or Amsterdam inherit the most recently configured BPO entry and must not
%% declare their own BlobConfig." So `osaka' takes Prague's row on every network, because
%% on all three BPO1 is scheduled *after* Osaka. That is a fact about the schedules and
%% not a rule about names, and `blob_schedule/1` gets it by walking down the ranks
%% rather than by naming forks -- see there.
blob_schedule(Fork) ->
    case blob_row(Fork) of
        {ok, Row} -> Row;
        none -> nearest_row(fork_rank(Fork))
    end.

%% **The rows, by name.** Only a fork the chain configuration gives a `BlobScheduleConfig'
%% entry has one, and the two named forks that must *not* have one are absent on purpose.
blob_row(cancun) -> {ok, {3, 6, 3338477}};
blob_row(prague) -> {ok, {6, 9, 5007716}};
blob_row(bpo1)   -> {ok, {10, 15, 8346193}};
blob_row(bpo2)   -> {ok, {14, 21, 11684671}};
blob_row(bpo3)   -> {ok, {21, 32, 20609697}};
blob_row(bpo4)   -> {ok, {14, 21, 13739630}};
blob_row(_Fork)  -> none.

%% **The row a fork uses is the nearest row at or below it, not a row named after it.**
%%
%% Osaka and Amsterdam carry no row of their own and inherit one, so the lookup walks down
%% from the fork's rank to the highest-ranked fork that *has* a row. Naming the forks
%% instead would need a row per named fork, and the two lists would then be able to
%% disagree -- which is the shape of the defect this table replaced: one Cancun figure
%% serving every fork, in a comment that admitted it.
%%
%% The rows themselves are the four ranks at which the chain configuration declares a
%% `BlobScheduleConfig' entry, which is `cancun, prague, bpo1 .. bpo4'.
%% **The walk lists only the rows that have a rank**, and that is four of the six.
%% `fork_rank/1' has no clause for `bpo3' or `bpo4' -- no network has scheduled them --
%% so they rank 0 and the walk would step straight past them. `blob_schedule/1' still
%% answers for them when a caller names one directly, so scheduling either is a data
%% change and not a code change.
%%
%% **The list was wrong twice before this line was right.** It began with `cancun' and
%% contained it twice, so `cancun' matched the first candidate for every fork and
%% `blob_schedule(osaka)' answered Cancun's row. Every test in `eth_4844_tests' that
%% asked what Prague changes failed at once, which is the only reason the list was read
%% rather than assumed -- **a candidate list is a claim about order and has to be
%% written in the order it is walked.**
nearest_row(Rank) -> nearest_row(Rank, [bpo2, bpo1, prague, cancun]).

%% Every fork below Cancun, and any fork whose rank is below Cancun's, uses Cancun's row:
%% it is the only one that was in force before EIP-7691 and there is no earlier blob
%% schedule to inherit from.
nearest_row(_Rank, []) -> {3, 6, 3338477};
nearest_row(Rank, [Candidate | Rest]) ->
    case fork_rank(Candidate) =< Rank of
        true ->
            %% **The `{ok, _}' wrapper has to come off here.** `blob_row/1' returns it so
            %% that "this fork has no row" is a value rather than a crash, and the two
            %% callers want opposite things: `blob_schedule/1' unwraps, the walk below
            %% hands the row straight out. Leaving the wrapper on leaked it to every
            %% caller, and `blob_gas_price/2' destructures a three-tuple -- so the first
            %% symptom was a `{ok, {6, 9, 5007716}}' where a row belonged.
            {ok, Row} = blob_row(Candidate),
            Row;
        false ->
            nearest_row(Rank, Rest)
    end.

%% EIP-4844: "ensure that the total blob gas spent is at most equal to the limit",
%% over the whole block. **Not a per-transaction condition**, and that distinction is
%% the rule: a 4-blob transaction followed by a 3-blob one makes an invalid block
%% whose transactions are each individually valid, so no per-transaction check can
%% enforce it and a check written per transaction would be a different rule wearing
%% the same name.
%%
%% **The max is a fork parameter and was not one.** At Cancun it is 786,432 -- six blobs,
%% which is EIP-4844's own table entry and exactly `6 * blob_gas_per_blob/0', written as
%% the product so a second literal for a figure that is another figure times six cannot
%% drift. At Prague it is nine blobs, at BPO2 twenty-one.
max_blob_gas_per_block(Fork) ->
    {_Target, MaxBlobs, _Fraction} = blob_schedule(Fork),
    MaxBlobs * blob_gas_per_blob().

target_blob_gas_per_block(Fork) ->
    {TargetBlobs, _Max, _Fraction} = blob_schedule(Fork),
    TargetBlobs * blob_gas_per_blob().

%% Excess blob gas carried into this block: the parent's excess plus the gas
%% its blobs consumed, less the per-block target, floored at zero.
%%
%% **The target is a fork parameter and was not one.** At Cancun it is 393,216 -- three
%% blobs -- so a Prague block was having six blobs' worth of gas subtracted per block and
%% a BPO2 block fourteen, which moves the excess counter by a third to five times the
%% correct amount and therefore every blob base fee derived from it.
excess_blob_gas(Fork, ParentExcessBlobGas, ParentBlobGasUsed, ParentBaseFeePerGas)
  when is_integer(ParentExcessBlobGas), is_integer(ParentBlobGasUsed) ->
    case blob_schedule(Fork) of
        {TargetBlobs, MaxBlobs, _Fraction} ->
            TargetBlobGas = TargetBlobs * blob_gas_per_blob(),
            case ParentExcessBlobGas + ParentBlobGasUsed < TargetBlobGas of
                true ->
                    0;
                false ->
                    %% **EIP-7918, quoted whole** (eip-7918.md, "Functions"):
                    %%
                    %%     if BLOB_BASE_COST * parent.base_fee_per_gas >
                    %%        GAS_PER_BLOB * get_base_fee_per_blob_gas(parent):
                    %%         return parent.excess_blob_gas
                    %%              + parent.blob_gas_used * (max - target) // max
                    %%     else:
                    %%         return parent.excess_blob_gas
                    %%              + parent.blob_gas_used - target_blob_gas
                    %%
                    %% **This node had only the `else` branch**, which is EIP-4844 verbatim,
                    %% and it is a *consensus* defect rather than a stale fee: the two
                    %% branches disagree by `used - used*(max-target)/max` on every block
                    %% where the reserve binds, so the node computed a different excess, a
                    %% different blob base fee, and then refused the block. It refused Sepolia
                    %% 11,846,220 with `{excess_blob_gas_mismatch, 210359169, 208961068}` and
                    %% stopped there forever.
                    %%
                    %% **The factor is `(max - target) / max`, not `(used - target)`, and for
                    %% Sepolia at BPO2 it is exactly 1/3** -- target 14, max 21. A subtraction
                    %% and a ratio that both reduce the increment are not the same rule: only
                    %% the ratio floors it at zero when a block uses nothing.
                    case below_reserve_price(Fork, ParentBaseFeePerGas,
                                             ParentExcessBlobGas) of
                        true ->
                            ParentExcessBlobGas
                            + ParentBlobGasUsed * (MaxBlobs - TargetBlobs) div MaxBlobs;
                        false ->
                            ParentExcessBlobGas + ParentBlobGasUsed - TargetBlobGas
                    end
            end
    end;
excess_blob_gas(_Fork, _ParentExcessBlobGas, _ParentBlobGasUsed, _ParentBaseFee) ->
    0.

%% **EIP-7918 is gated on Osaka and was applied at every fork before.**
%%
%% Three things have to be true together and the gate is what makes them consistent:
%% the fork is at least `osaka', the parent's base fee is a number, and the reserve
%% price exceeds the blob price. **The base fee only enters the comparison**, never the
%% result -- a block's excess depends on its parent's base fee, which is why this
%% function grew an argument rather than being given the parent's header.
%%
%% Pre-Osaka the comparison is skipped entirely, which is what keeps every pre-Osaka
%% figure in this module bit-identical to what it was before EIP-7918 existed.
below_reserve_price(Fork, ParentBaseFeePerGas, ParentExcessBlobGas) ->
    at_least(Fork, osaka)
        andalso is_integer(ParentBaseFeePerGas)
        andalso ?BLOB_BASE_COST * ParentBaseFeePerGas
                 > blob_gas_per_blob() * blob_gas_price(Fork, ParentExcessBlobGas).

blob_base_fee(Fork, ParentExcessBlobGas, ParentBlobGasUsed, ParentBaseFeePerGas) ->
    blob_gas_price(Fork,
                   excess_blob_gas(Fork, ParentExcessBlobGas, ParentBlobGasUsed,
                                   ParentBaseFeePerGas)).

%% Blob gas price as a function of excess blob gas. This is the EIP-4844
%% fake_exponential with the minimum price as its base, so a block whose
%% predecessors used no more than the target charges 1 wei per blob gas.
%%
%% **The update fraction is a fork parameter and was not one.** Cancun divides by 3,338,477
%% and Prague by 5,007,716, so the curve is materially flatter after Prague: at the same
%% excess, a Prague block charges *less* per blob gas than a Cancun block would.
blob_gas_price(Fork, ExcessBlobGas) when is_integer(ExcessBlobGas) ->
    {_Target, _Max, Fraction} = blob_schedule(Fork),
    fake_exponential(?MIN_BLOB_GASPRICE, max(0, ExcessBlobGas), Fraction);
blob_gas_price(_Fork, _ExcessBlobGas) ->
    ?MIN_BLOB_GASPRICE.

%% fake_exponential(Factor, Numerator, Denominator), as defined in EIP-4844.
%% The series is accumulated as Factor*Denominator and repeatedly scaled by
%% Numerator/(Denominator*i); the final division by Denominator is what makes
%% the i=1 term come out as exactly Factor.
fake_exponential(Factor, Numerator, Denominator)
  when is_integer(Factor), is_integer(Numerator), is_integer(Denominator),
       Denominator > 0 ->
    fe(Factor, Numerator, Denominator, 1, 0, Factor * Denominator).

fe(_Factor, _Numerator, Denominator, _I, Output, Acc) when Acc =< 0 ->
    Output div Denominator;
fe(Factor, Numerator, Denominator, I, Output, Acc) ->
    Next = (Acc * Numerator) div (Denominator * I),
    fe(Factor, Numerator, Denominator, I + 1, Output + Acc, Next).

%% ---------------------------------------------------------------------------
%% EIP-4895 withdrawals
%% ---------------------------------------------------------------------------

%% Withdrawals are already ordered by the consensus layer.  Sorting here is
%% still useful for callers constructing a payload locally and makes the
%% ordering invariant explicit.
process_withdrawals(_BlockNumber, Withdrawals) when is_list(Withdrawals) ->
    lists:sort(fun(A, B) -> withdrawal_index(A) =< withdrawal_index(B) end,
              Withdrawals);
process_withdrawals(_BlockNumber, _Withdrawals) ->
    [].

make_withdrawal(Index, Address, Amount) ->
    #{index => Index,
      validatorIndex => Index,
      address => Address,
      amount => Amount}.

withdrawal_index(#{index := Index}) -> Index;
withdrawal_index(#{<<"index">> := Index}) -> Index;
withdrawal_index(_) -> 0.

withdrawal_address(#{address := Address}) -> Address;
withdrawal_address(#{<<"address">> := Address}) -> Address;
withdrawal_address(_) -> <<>>.

withdrawal_amount(#{amount := Amount}) -> Amount;
withdrawal_amount(#{<<"amount">> := Amount}) -> Amount;
withdrawal_amount(_) -> 0.

%% withdrawalsRoot commits to the withdrawals list as a Merkle-Patricia trie,
%% keyed by the withdrawal's *position* in the list and valued with the RLP of
%% the withdrawal's four fields. This is the same construction as the
%% transactions root, which is what the EIP says, and the reference spec
%% implements it identically:
%%
%%     for i, wd in enumerate(withdrawals):
%%         trie_set(trie, rlp.encode(Uint(i)), rlp.encode(wd))
%%
%% The key is the position, not the withdrawal's own `index' field -- those are
%% different numbers, and conflating them yields a root that matches nothing.
%%
%% An empty list therefore gives the canonical empty-trie root, not a hash of
%% an empty SSZ list. An earlier implementation here used SSZ, which produces a
%% plausible 32-byte value that no other client would ever produce; against a
%% real Shanghai block it disagreed on every field.
%%
%% EIP-4895 caps a payload at ?MAX_WITHDRAWALS_PER_PAYLOAD entries, so a longer
%% list is truncated before the root is computed. A payload that exceeds the cap
%% is invalid rather than merely clamped, so callers must check the length
%% separately; the root itself stays well defined either way.
withdrawals_root(Withdrawals) when is_list(Withdrawals) ->
    Capped = lists:sublist(Withdrawals, ?MAX_WITHDRAWALS_PER_PAYLOAD),
    Pairs = [{eth_rlp:encode(Pos), withdrawal_rlp(W)}
             || {Pos, W} <- lists:zip(lists:seq(0, length(Capped) - 1), Capped)],
    eth_trie:root(Pairs);
withdrawals_root(_Withdrawals) ->
    withdrawals_root([]).

%% The one place `?MAX_WITHDRAWALS_PER_PAYLOAD' is readable from outside. Exported as
%% a function rather than duplicated as a macro in `eth_block', because a constant
%% with two homes is the defect AGENTS.md §3 is about -- the same shape as the
%% interpreter's deleted second copy of the gas table.
-spec max_withdrawals_per_payload() -> pos_integer().
max_withdrawals_per_payload() -> ?MAX_WITHDRAWALS_PER_PAYLOAD.

%% RLP([index, validator_index, address, amount]) -- all four fields integers or
%% a 20-byte string, in that order. eth_rlp encodes an integer 0 as the empty
%% string and a positive integer as minimal big-endian bytes, which is what the
%% spec's U64 encoding does.
withdrawal_rlp(Withdrawal) ->
    Index = withdrawal_integer(withdrawal_index(Withdrawal)),
    Validator = withdrawal_integer(withdrawal_validator_index(Withdrawal)),
    Address = withdrawal_binary(withdrawal_address(Withdrawal)),
    Amount = withdrawal_integer(withdrawal_amount(Withdrawal)),
    eth_rlp:encode([Index, Validator, Address, Amount]).

withdrawal_validator_index(#{validatorIndex := I}) -> I;
withdrawal_validator_index(#{<<"validatorIndex">> := I}) -> I;
withdrawal_validator_index(#{validator_index := I}) -> I;
withdrawal_validator_index(#{<<"validator_index">> := I}) -> I;
withdrawal_validator_index(_) -> 0.

%% A payload off the wire carries these as JSON-RPC quantities: "0x175" is the
%% *hexadecimal* number 373, not the three ASCII bytes "175" and not the
%% big-endian integer 321. It has to be parsed base 16, which is also what
%% eth_hex:decode/1 does. Reading it as big-endian bytes yields a plausible
%% number that is simply the wrong one, so the root would disagree with every
%% other client while looking entirely healthy.
%%
%% Locally built withdrawals use plain integers, which pass through. A binary
%% that is not a hex-digit string at all is treated as raw big-endian bytes,
%% which is the only other meaning a 32-byte word can have here.
withdrawal_integer(I) when is_integer(I) -> max(0, I);
withdrawal_integer(B) when is_binary(B) ->
    case eth_hex:is_hex(B) of
        true ->
            try max(0, eth_hex:decode(B)) catch _:_ -> 0 end;
        false ->
            try max(0, binary:decode_unsigned(B)) catch _:_ -> 0 end
    end;
withdrawal_integer(_) -> 0.

%% The address must reach RLP as exactly 20 raw bytes. A "0x"-prefixed string
%% would encode as 21 bytes and commit to something no other client computes.
withdrawal_binary(<<"0x", Rest/binary>>) when byte_size(Rest) =:= 40 ->
    binary:decode_hex(Rest);
withdrawal_binary(<<A:20/binary>>) -> A;
withdrawal_binary(<<>>) -> <<0:160>>;
withdrawal_binary(B) when is_binary(B) ->
    Pad = 20 - byte_size(B),
    case Pad >= 0 of
        true -> <<0:(Pad * 8), B/binary>>;
        false -> binary:part(B, byte_size(B) - 20, 20)
    end;
withdrawal_binary(_) -> <<0:160>>.

%% Credit withdrawals to the execution state.  Amounts are denominated in
%% Gwei, as required by EIP-4895.  The helper is intentionally separate from
%% payload ordering so callers can apply the list only after the block's
%% transactions have committed.
apply_withdrawals(Withdrawals) when is_list(Withdrawals) ->
    try
        lists:foreach(fun apply_withdrawal/1, Withdrawals),
        {ok, length(Withdrawals)}
    catch
        exit:{noproc, _} -> {error, state_unavailable};
        exit:{{nodedown, _}, _} -> {error, state_unavailable};
        _:_ -> {error, state_update_failed}
    end;
apply_withdrawals(_) ->
    {error, bad_withdrawals}.

%% The state-overlay form, which is what block execution needs.
%%
%% apply_withdrawals/1 writes straight to the MPT, so a credit made during block
%% processing would sit outside the overlay and outside the state root -- the
%% balance would exist on disk but not in the commitment the block declares. A
%% withdrawal is part of the block's state transition, so it belongs in the same
%% overlay its transactions write to.
%%
%% Amounts arrive in Gwei and are credited in wei. Two withdrawals to the same
%% address must accumulate, so each read is taken from the state as it stands
%% after the previous one rather than from a snapshot.
apply_withdrawals_to_state(Withdrawals, State) when is_list(Withdrawals) ->
    apply_withdrawals_to_state(Withdrawals, State, 0);
apply_withdrawals_to_state(_Withdrawals, State) ->
    {ok, State, 0}.

apply_withdrawals_to_state([], State, N) ->
    {ok, State, N};
apply_withdrawals_to_state([Withdrawal | Rest], State, N) ->
    case withdrawal_binary(withdrawal_address(Withdrawal)) of
        <<Address:20/binary>> ->
            Amount = withdrawal_integer(withdrawal_amount(Withdrawal)) * 1000000000,
            Balance = eth_state:balance(State, Address) + Amount,
            %% A withdrawal can be the first thing to touch an account. Creating
            %% it does not raise its nonce, and the EIP-1052 empty-code hash is
            %% what every other node would record.
            Nonce = eth_state:nonce(State, Address),
            State1 = eth_state:set_balance(State, Address, Balance),
            State2 = eth_state:set_nonce(State1, Address, Nonce),
            apply_withdrawals_to_state(Rest, State2, N + 1);
        _ ->
            {error, bad_withdrawal_address, State, N}
    end.

apply_withdrawal(Withdrawal) ->
    Address = withdrawal_binary(withdrawal_address(Withdrawal)),
    case byte_size(Address) of
        20 ->
            {Balance, Nonce, CodeHash} = account_triple(eth_mpt:get_account(Address)),
            Amount = withdrawal_integer(withdrawal_amount(Withdrawal)) * 1000000000,
            ok = eth_mpt:put_account(Address, Balance + Amount, Nonce, CodeHash);
        _ ->
            throw(bad_withdrawal_address)
    end.

account_triple(#{balance := Balance, nonce := Nonce, codeHash := CodeHash})
  when is_integer(Balance), is_integer(Nonce) ->
    {Balance, Nonce, CodeHash};
account_triple(_) ->
    %% A withdrawal may credit an address that has never been touched. Such an
    %% account starts empty with the EIP-1052 empty-code hash.
    {0, 0, eth_keccak:hash(<<>>)}.

%% ---------------------------------------------------------------------------
%% EIP-4788 beacon roots
%% ---------------------------------------------------------------------------

beacon_root_contract() ->
    ?BEACON_ROOTS_ADDRESS.

system_address() ->
    ?SYSTEM_ADDRESS.

history_buffer_length() ->
    ?HISTORY_BUFFER_LENGTH.

%% The contract keeps two ring buffers, not one. Slot `ts mod 8191' holds the
%% timestamp that wrote there and slot `ts mod 8191 + 8191' holds the beacon
%% root; `get' re-reads the timestamp and reverts if it does not match, which is
%% what stops a skipped slot sharing a ring index from returning a stale root.
%%
%% A single buffer keyed by the full timestamp looks like a reasonable encoding
%% and is what an earlier version here did. It is also unreachable: the contract
%% only ever touches these two ranges, so every lookup would miss.
%%
%% Verified against Sepolia: at the latest block, storage[ts mod 8191] is exactly
%% ts and storage[ts mod 8191 + 8191] is exactly parentBeaconBlockRoot.
beacon_root_slots(Timestamp) when is_integer(Timestamp) ->
    Index = Timestamp rem ?HISTORY_BUFFER_LENGTH,
    {Index, Index + ?HISTORY_BUFFER_LENGTH}.

%% Write the (timestamp, root) pair for this block. Kept separate from the system
%% call below because the EIP permits a client to set the slots directly; doing
%% so is only equivalent where the deployed code is the specified code, which is
%% why process_beacon_roots/3 prefers to actually run it.
store_beacon_root(Timestamp, Root, State) when is_integer(Timestamp),
                                             is_binary(Root),
                                             byte_size(Root) =:= 32 ->
    {TimestampSlot, RootSlot} = beacon_root_slots(Timestamp),
    S1 = eth_state:set_storage(State, ?BEACON_ROOTS_ADDRESS, TimestampSlot,
                               Timestamp),
    S2 = eth_state:set_storage(S1, ?BEACON_ROOTS_ADDRESS, RootSlot, Root),
    {ok, S2};
store_beacon_root(_Timestamp, _Root, _State) ->
    {error, invalid_beacon_root}.

%% The read side, mirroring the contract's `get' before it reverts on a
%% timestamp mismatch. The root is returned as a 32-byte word so a caller can
%% tell "no root" from "the zero root".
read_beacon_root(Timestamp, State) when is_integer(Timestamp) ->
    {TimestampSlot, RootSlot} = beacon_root_slots(Timestamp),
    case eth_state:storage(State, ?BEACON_ROOTS_ADDRESS, TimestampSlot) of
        Timestamp ->
            {ok, word(eth_state:storage(State, ?BEACON_ROOTS_ADDRESS, RootSlot))};
        _ ->
            {error, unknown_timestamp}
    end.

%% A storage slot holds a word, and this codebase has two representations of
%% one: the EVM's stack is integers, so a value written by the deployed contract
%% comes back from eth_state:storage/3 as an integer, while store_beacon_root/3
%% above hands it a 32-byte binary. Both are reachable -- process_beacon_roots/4
%% runs the contract, and the direct write is the EIP's permitted shortcut -- so
%% the read side normalizes both instead of handling only the shape its author
%% happened to test. Before the system address was corrected nothing ever wrote
%% through the EVM, so the integer clause was unreachable and this did not show.
word(<<>>) -> <<0:256>>;
word(V) when is_binary(V) -> V;
word(V) when is_integer(V) -> <<V:256/unsigned-big>>.

%% The EIP-4788 system operation, run at the start of every block whose
%% timestamp is at or after the fork.
%%
%% This executes the contract's code as the system caller rather than writing
%% the two slots directly. The EIP allows the shortcut, but only where the code
%% at BEACON_ROOTS_ADDRESS is the code the EIP specifies; on a network that
%% deployed something else, hardcoding the slots would silently commit to a
%% state nobody else computed. The spec also requires the call to complete or
%% fail silently, and requires it not to count against the block gas limit --
%% so the gas it uses is not added to gas_used.
%%
%% Returns the state unchanged when the fork is not active, when the parent
%% beacon root is the zero placeholder, or when there is no code at the address.
process_beacon_roots(Timestamp, Root, State, Fork) ->
    case beacon_roots_active(Root, Fork) of
        false ->
            {ok, State};
        true ->
            run_system_call(Root, Timestamp, 0, State,
                            ?BEACON_ROOTS_ADDRESS, ?BEACON_ROOTS_GAS, Fork)
    end.

%% The shape both system operations share: call the contract as the system
%% caller with the given calldata, and treat every outcome as "the block
%% proceeds" because each EIP says a failed call is to be ignored.
%%
%% Timestamp and BlockNumber are passed separately because the two contracts
%% disagree about which of them they use: the beacon-roots contract derives its
%% ring index from TIMESTAMP and never reads NUMBER, while the EIP-2935 contract
%% derives its ring index from NUMBER and never reads TIMESTAMP. Supplying a real
%% block's timestamp while pinning the number to 0 (or the reverse) states that
%% the unused opcode is genuinely unobserved by the deployed code, rather than
%% feeding it a value that would only be right by accident.
run_system_call(Calldata, Timestamp, BlockNumber, State, Address, Gas, Fork) ->
    Code = eth_state:code(State, Address),
    case Code of
        <<>> ->
            %% "if no code exists at ... ADDRESS, the call must fail silently"
            {ok, State};
        _ ->
            Msg = #{caller => ?SYSTEM_ADDRESS,
                    origin => ?SYSTEM_ADDRESS,
                    address => Address,
                    value => 0,
                    data => Calldata,
                    gas_price => 0,
                    static => false,
                    depth => 0},
            Env = #{timestamp => Timestamp, number => BlockNumber,
                    coinbase => <<0:160>>, prevrandao => <<0:256>>,
                    gas_limit => 0, base_fee => 0,
                    chain_id => chain_id(),
                    %% The fork, from the caller that already resolved it. Both
                    %% system contracts are Cancun- and Prague-era code
                    %% respectively, so running either under the wrong schedule
                    %% would be a fork-gate answering the wrong question -- but
                    %% the gate is checked there, and a frame still needs a fork
                    %% to execute under.
                    fork => Fork,
                    state => State},
            %% The call must "execute to completion" or "fail silently", so
            %% neither outcome is an error here -- and neither is charged to the
            %% block's gas limit, which is why the gas left over is discarded.
            try eth_evm:run(Code, Msg, State, Env, Gas) of
                {ok, _Out, _GasLeft, St, _Logs} -> {ok, St};
                {revert, _Out, _GasLeft, _St, _Logs} -> {ok, State};
                {error, _Reason, _St, _Logs} -> {ok, State}
            catch
                _:_ -> {ok, State}
            end
    end.

%% Cancun and later. A parent beacon block root of all zeros is the genesis
%% placeholder and must not trigger the call.
beacon_roots_active(undefined, _Fork) -> false;
beacon_roots_active(<<0:256>>, _Fork) -> false;
beacon_roots_active(<<Root:32/binary>>, _Fork) when Root == <<0:256>> -> false;
beacon_roots_active(_Root, Fork) ->
    lists:member(Fork, [cancun, prague, osaka, amsterdam, bpo1, bpo2, bpo3, bpo4, bpo5]).

add_beacon_root_to_state(Timestamp, Root) ->
    {TimestampSlot, _RootSlot} = beacon_root_slots(Timestamp),
    case Root of
        <<R:32/binary>> ->
            eth_mpt:put_storage(?BEACON_ROOTS_ADDRESS,
                                <<TimestampSlot:256>>, R);
        _ ->
            {error, invalid_beacon_root}
    end.

get_beacon_root_from_state(Timestamp) ->
    {TimestampSlot, RootSlot} = beacon_root_slots(Timestamp),
    case eth_mpt:get_storage(?BEACON_ROOTS_ADDRESS,
                              <<TimestampSlot:256>>) of
        Timestamp -> eth_mpt:get_storage(?BEACON_ROOTS_ADDRESS, <<RootSlot:256>>);
        _ -> {error, unknown_timestamp}
    end.

add_beacon_root(Timestamp, Root) ->
    try add_beacon_root_to_state(Timestamp, Root)
    catch exit:{noproc, _} -> {error, state_unavailable}
    end.

get_beacon_root(Timestamp) ->
    try get_beacon_root_from_state(Timestamp)
    catch exit:{noproc, _} -> {error, state_unavailable}
    end.

%% ---------------------------------------------------------------------------
%% EIP-2935 block hash history
%% ---------------------------------------------------------------------------

history_storage_address() ->
    ?HISTORY_STORAGE_ADDRESS.

%% HISTORY_SERVE_WINDOW. The ring has this many slots, which is why the contract
%% can serve 8191 block hashes out of 8191 storage slots rather than one per
%% block.
history_serve_window() ->
    ?HISTORY_BUFFER_LENGTH.

%% The ring index for a parent block number.
%%
%% Note that this is the *block number* mod 8191, not the timestamp. The
%% beacon-roots ring above is keyed by timestamp; reusing that keying here would
%% be a plausible-looking mistake that the two EIPs do not share. The distinction
%% is visible in the deployed contract: its write path computes
%% `(block.number - 1) mod 8191` and never touches TIMESTAMP.
history_slot(ParentNumber) when is_integer(ParentNumber), ParentNumber >= 0 ->
    ParentNumber rem ?HISTORY_BUFFER_LENGTH;
history_slot(_ParentNumber) ->
    {error, invalid_block_number}.

%% Write the parent hash into the ring directly, for the same reason
%% store_beacon_root/3 exists: the EIP permits it, and process_history/4 prefers
%% running the deployed code because the shortcut is only equivalent when that
%% code is the code the EIP specifies.
store_parent_hash(ParentNumber, ParentHash, State)
  when is_integer(ParentNumber), is_binary(ParentHash),
       byte_size(ParentHash) =:= 32 ->
    case history_slot(ParentNumber) of
        {error, _} = E -> E;
        Slot ->
            {ok, eth_state:set_storage(State, ?HISTORY_STORAGE_ADDRESS,
                                       Slot, ParentHash)}
    end;
store_parent_hash(_ParentNumber, _ParentHash, _State) ->
    {error, invalid_parent_hash}.

%% The public read, mirroring the contract's `get': a block number in the
%% trailing 8191-block window resolves to the hash of *its* parent.
%%
%% The window is [BlockNumber - 8191, BlockNumber - 1]. Outside it the contract
%% reverts, and this returns an error rather than a hash so a caller cannot
%% mistake "outside the window" for "this block had no parent recorded". Within
%% it a slot that was never written reads as zero, which is indistinguishable
%% from a genuine parent hash of zero -- so a client must treat a zero result as
%% absent, exactly as it must for the beacon-roots ring.
read_parent_hash(QueryNumber, BlockNumber, State)
  when is_integer(QueryNumber), is_integer(BlockNumber) ->
    Parent = BlockNumber - 1,
    case {QueryNumber > Parent, BlockNumber - QueryNumber > ?HISTORY_BUFFER_LENGTH} of
        {true, _} -> {error, block_number_in_future};
        {_, true} -> {error, block_number_too_old};
        {false, false} ->
            {ok, word(eth_state:storage(State, ?HISTORY_STORAGE_ADDRESS,
                                        QueryNumber rem ?HISTORY_BUFFER_LENGTH))}
    end;
read_parent_hash(_QueryNumber, _BlockNumber, _State) ->
    {error, invalid_block_number}.

%% The EIP-2935 system operation, run at the start of every Prague-or-later
%% block: the block being processed calls HISTORY_STORAGE_ADDRESS as the system
%% caller, passing its own parent's hash, and the contract records that hash at
%% ring index (block.number - 1) mod 8191.
%%
%% As with EIP-4788 above, this executes the contract's code rather than writing
%% the slot directly, so that a network which deployed something else at the
%% address is handled by that code instead of being silently disagreed with. The
%% EIP's escape hatches are the same: no code means fail silently, a revert or
%% error means fail silently, and the 30M gas is not charged to the block's gas
%% limit.
process_history(ParentHash, BlockNumber, State, Fork) ->
    case history_active(Fork) of
        false ->
            {ok, State};
        true ->
            run_system_call(ParentHash, 0, BlockNumber, State,
                            ?HISTORY_STORAGE_ADDRESS, ?HISTORY_GAS, Fork)
    end.

%% Prague and later. Unlike EIP-4788 there is no zero-placeholder exemption: the
%% parent hash of a real block is never the genesis placeholder here, and the
%% contract is specified to store whatever it is handed.
history_active(Fork) ->
    lists:member(Fork, [prague, osaka, amsterdam, bpo1, bpo2, bpo3, bpo4, bpo5]).

%% ---------------------------------------------------------------------------
%% Gas schedule
%% ---------------------------------------------------------------------------

%% Gas is the dynamic byte-length argument for the opcode (for example, the
%% data length for KECCAK256).  Args may contain `warm' => true|false and
%% `new_account' => true|false for EIP-2929/EIP-1615.  Memory expansion is
%% charged by the caller, just as in the EVM interpreter, so it is not
%% double-counted here.
%%
%% State-reading opcodes (BALANCE, EXTCODESIZE, EXTCODEHASH, EXTCODE*, and the
%% CALL family) are charged a *cold* cost by default because a call that has
%% not yet touched the address is the common case. Passing #{warm => true}
%% returns the EIP-2929 warm cost instead, which is what the interpreter must
%% use for an address already in the access list or touched earlier in the
%% transaction.
gas_cost(Opcode, Fork, Gas) when is_integer(Opcode), is_integer(Gas) ->
    gas_cost(Opcode, Fork, Gas, #{});
gas_cost(_Opcode, _Fork, _Gas) ->
    0.

gas_cost(Opcode, Fork, Gas, Args) when is_map(Args) ->
    Base = base_gas_cost(Opcode, Fork, Args),
    Dynamic = dynamic_gas_cost(Opcode, Fork, max(0, Gas), Args),
    Base + Dynamic;
gas_cost(Opcode, Fork, Gas, _Args) ->
    gas_cost(Opcode, Fork, Gas).

%% Base (constant) gas per opcode, for Cancun-era rules unless a clause says
%% otherwise. This table was wrong for eighteen opcodes before 2026-09; the
%% specific failures are named beside the clauses that now carry the right
%% values, because each was a plausible-looking mistake rather than a typo.
base_gas_cost(16#00, _, _) -> 0;                                   % STOP
base_gas_cost(16#01, _, _) -> 3;                                   % ADD
base_gas_cost(16#02, _, _) -> 5;                                   % MUL
base_gas_cost(16#03, _, _) -> 3;                                   % SUB
base_gas_cost(16#04, _, _) -> 5;                                   % DIV
base_gas_cost(16#05, _, _) -> 5;                                   % SDIV
base_gas_cost(16#06, _, _) -> 5;                                   % MOD
base_gas_cost(16#07, _, _) -> 5;                                   % SMOD
base_gas_cost(16#08, _, _) -> 8;                                   % ADDM
base_gas_cost(16#09, _, _) -> 8;                                   % MULMOD
base_gas_cost(16#0A, _, _) -> 10;                                  % EXP
base_gas_cost(16#0B, _, _) -> 5;                                   % SIGNEXTEND
base_gas_cost(Op, _, _) when Op >= 16#10, Op =< 16#1D -> 3;
base_gas_cost(16#20, _, _) -> 30;                                  % KECCAK256
base_gas_cost(16#30, _, _) -> 2;                                   % ADDRESS
base_gas_cost(16#31, Fork, Args) -> access_cost(16#31, Fork, Args);  % BALANCE
base_gas_cost(16#32, _, _) -> 2;                                   % ORIGIN
base_gas_cost(16#33, _, _) -> 2;                                   % CALLER
base_gas_cost(16#34, _, _) -> 2;                                   % CALLVALUE
base_gas_cost(16#35, _, _) -> 3;                                   % CALLDATALOAD
%% CALLDATASIZE, CODESIZE and GASPRICE are 2. These three sat in a 0x35-0x3A
%% range priced at 3, which is the price of the *operations* in the same block
%% of the opcode table; a range is the wrong tool across a block where only
%% some of the members share a cost.
base_gas_cost(16#36, _, _) -> 2;
base_gas_cost(16#37, _, _) -> 3;                                   % CALLDATACOPY
base_gas_cost(16#38, _, _) -> 2;                                   % CODESIZE
base_gas_cost(16#39, _, _) -> 3;                                   % CODECOPY
base_gas_cost(16#3A, _, _) -> 2;                                   % GASPRICE
base_gas_cost(16#3B, Fork, Args) -> access_cost(16#3B, Fork, Args);  % EXTCODESIZE
base_gas_cost(16#3C, Fork, Args) -> access_cost(16#3C, Fork, Args);  % EXTCODECOPY
%% RETURNDATASIZE is 2. It was routed through access_cost/3, so a Cancun read
%% cost 2600 -- a thousand times the real price, and enough to out-of-gas a loop
%% that loops over return data. RETURNDATACOPY is the one with a per-word cost,
%% and it is 3.
base_gas_cost(16#3D, _, _) -> 2;
base_gas_cost(16#3E, _, _) -> 3;
base_gas_cost(16#3F, Fork, Args) -> access_cost(16#3F, Fork, Args);  % EXTCODEHASH
base_gas_cost(16#40, _, _) -> 20;                                  % BLOCKHASH
base_gas_cost(Op, _, _) when Op >= 16#41, Op =< 16#46 -> 2;
%% EIP-7843: "The gas cost for SLOTNUM is a fixed fee of 2." It sits inside the 0x41..0x46
%% range that already charges 2, so the range cannot simply be widened to 0x4B: 0x47
%% SELFBALANCE is 5 and 0x49/0x4A carry Cancun's own prices, and widening the guard would
%% silently reprice four instructions to fix one.
base_gas_cost(16#4B, _, _) -> 2;
%% SELFBALANCE is 5. It shared a clause with CREATE and CREATE2 -- the three
%% opcodes that read the *caller's* account -- and inherited 32000. A contract
%% checking its own balance could not afford to do so.
base_gas_cost(16#47, _, _) -> 5;
base_gas_cost(16#48, _, _) -> 20;                                  % BASEFEE
base_gas_cost(16#49, _, _) -> 20;                                  % BLOBHASH
base_gas_cost(16#4A, _, _) -> 20;                                  % BLOBBASEFEE
base_gas_cost(16#50, _, _) -> 2;                                   % POP
base_gas_cost(16#51, _, _) -> 3;                                   % MLOAD
base_gas_cost(16#52, _, _) -> 3;                                   % MSTORE
base_gas_cost(16#53, _, _) -> 3;                                   % MSTORE8
%% SLOAD is EIP-2929 warm/cold, and its cold cost is 2100 rather than the 2600
%% an account access costs. It was inside a 0x50-0x5B range priced at 2, so a
%% storage read was 1050x too cheap.
base_gas_cost(16#54, Fork, Args) -> access_cost(16#54, Fork, Args);
base_gas_cost(16#55, _, _) -> 0;                                   % SSTORE, all dynamic
%% JUMP and JUMPI are 8 and 10. Like the CALLDATASIZE group above they were
%% swept into a range that priced them at 2.
base_gas_cost(16#56, _, _) -> 8;
base_gas_cost(16#57, _, _) -> 10;
base_gas_cost(16#58, _, _) -> 2;                                   % PC
base_gas_cost(16#59, _, _) -> 2;                                   % MSIZE
base_gas_cost(16#5A, _, _) -> 2;                                   % GAS
base_gas_cost(16#5B, _, _) -> 1;                                   % JUMPDEST
%% TLOAD, TSTORE, MCOPY and PUSH0 (Cancun) had no clause at all and fell to
%% the catch-all below, which prices an unassigned opcode at 0. So the first
%% two were free and MCOPY and PUSH0 were free. A catch-all of 0 is the
%% opposite of the safe default: an opcode nobody has costed is the one case
%% that should be conspicuous, and this is the reason gas_cost/3 was not
%% trustworthy despite its own tests passing.
base_gas_cost(16#5C, _, _) -> 100;                                 % TLOAD
base_gas_cost(16#5D, _, _) -> 100;                                 % TSTORE
base_gas_cost(16#5E, _, _) -> 3;                                   % MCOPY
base_gas_cost(16#5F, _, _) -> 2;                                   % PUSH0
base_gas_cost(Op, _, _) when Op >= 16#60, Op =< 16#7F -> 3;        % PUSH1..PUSH32
base_gas_cost(Op, _, _) when Op >= 16#80, Op =< 16#8F -> 3;        % DUP1..DUP16
base_gas_cost(Op, _, _) when Op >= 16#90, Op =< 16#9F -> 3;        % SWAP1..SWAP16
base_gas_cost(Op, _, _) when Op >= 16#A0, Op =< 16#A4 -> 375 * (Op - 16#A0 + 1);
base_gas_cost(16#F0, Fork, _) -> account_creation_cost(Fork);       % CREATE
base_gas_cost(16#F1, Fork, Args) -> call_cost(16#F1, Fork, Args);  % CALL
base_gas_cost(16#F2, Fork, Args) -> call_cost(16#F2, Fork, Args);  % CALLCODE
base_gas_cost(16#F3, _, _) -> 0;                                   % RETURN
base_gas_cost(16#F4, Fork, Args) -> call_cost(16#F4, Fork, Args);  % DELEGATECALL
base_gas_cost(16#F5, Fork, _) -> account_creation_cost(Fork);       % CREATE2
base_gas_cost(16#FA, Fork, Args) -> call_cost(16#FA, Fork, Args);  % STATICCALL
base_gas_cost(16#FD, _, _) -> 0;                                   % REVERT
%% INVALID is priced 0, like RETURN and REVERT, because what it costs is not a
%% number: it is an exceptional halt that consumes the frame's whole allowance.
%% See eth_evm:run/5, whose error form deliberately carries no gas figure. It
%% was 5000 here, which is neither its price nor a halt.
base_gas_cost(16#FE, _, _) -> 0;
base_gas_cost(16#FF, Fork, _) -> selfdestruct_cost(Fork);           % SELFDESTRUCT
%% An opcode with no assigned cost. 0 is the right answer only for the ones
%% that are genuinely free and for the undefined opcodes, which cannot appear
%% in deployed code; it is a guess everywhere else, and gas_cost/3's own tests
%% did not notice for TLOAD, TSTORE, MCOPY and PUSH0 for exactly that reason.
base_gas_cost(_, _, _) -> 0.

%% SLOAD (EIP-2929). A cold slot costs 2100 and a warm one 100, from Berlin.
%% Pre-Berlin it was a flat 200, raised by E-150.
%% ---------------------------------------------------------------------------
%% Access costs, and the one owner of how a price is composed
%% ---------------------------------------------------------------------------
%% ---------------------------------------------------------------------------
%% An access-sensitive opcode has no constant part at all: BALANCE costs 2600
%% cold and 100 warm, and there is nothing left over that a machine loop could
%% charge before running it, because "cold" is not knowable until the opcode has
%% looked at what the frame has already touched. So `constant_cost/2' charges
%% **zero** for these, and the handler asks for the whole price here.
%%
%% That is the whole reason this is one function and not two. The interpreter used
%% to price a warm access at 100 and add a cold surcharge afterwards -- 2500 for
%% an account, 2000 for a slot -- while this table returned the *total* in one
%% figure. Both were internally consistent and they disagreed, so neither could be
%% substituted for the other: a cold BALANCE would have cost 5100. The surcharge
%% is gone, and the fork is in the figure.
%%
%% Keyed by opcode rather than taking the legacy cost as an argument, because the
%% pre-Berlin figure differs by opcode -- EIP-150 set BALANCE and EXTCODEHASH to
%% 400 while leaving EXTCODESIZE, EXTCODECOPY and the CALL family at 700 -- and an
%% argument invites the caller to pass the wrong one for its own opcode. Measured
%% across both tables, the legacy figures are the only per-opcode difference.

%% Both price figures for each access-sensitive opcode, as
%% {pre-Berlin (EIP-150), post-Berlin cold}. Warm is 100 from Berlin for all of
%% them, so it is not a per-opcode number and is not here.
%%
%% One table rather than an opcode-argument and a separate `sload_cost/2',
%% because that is what it was: SLOAD differed only in these two figures -- 200 and
%% 2100 against 400/700 and 2600 -- so it had its own function, and the two could
%% drift without anything noticing. SLOAD's cold cost is COLD_SLOAD_COST (2100) and
%% an account access is COLD_ACCOUNT_ACCESS_COST (2600); they are different
%% constants, not different regimes.
access_prices(16#31) -> {400, cold_account_access_cost()};   % BALANCE
access_prices(16#3B) -> {700, cold_account_access_cost()};   % EXTCODESIZE
access_prices(16#3C) -> {700, cold_account_access_cost()};   % EXTCODECOPY
access_prices(16#3F) -> {400, cold_account_access_cost()};   % EXTCODEHASH
access_prices(16#54) -> {sload_gas(homestead), 2100};   % SLOAD, see sload_gas/1
access_prices(Op) when Op >= 16#F1, Op =< 16#F4 -> {700, cold_account_access_cost()};  % the CALL family
access_prices(16#FA) -> {700, cold_account_access_cost()};   % STATICCALL
access_prices(_Op) -> {0, 0}.

%% EIP-2929's `COLD_ACCOUNT_ACCESS_COST`, which is what an account access costs
%% when that account is cold. Named because **it was written out six times** in
%% this table -- four here and once more for the call family -- and a fifth copy
%% for EIP-7702's delegation resolution would have been a seventh. It is 2600 and
%% it is not fork-selected: EIP-2929 is Berlin, and `access_cost/3` is what
%% decides whether Berlin's regime applies at all.
%%
%% It is distinct from `COLD_SLOAD_COST` (2100), which is the *storage* figure and
%% which EIP-2929 raises separately; a table that conflated them would be right
%% about four opcodes and wrong about SLOAD, so SLOAD keeps its own literal.
cold_account_access_cost() -> 2600.

%% EIP-7702: "If a code executing instruction accesses a cold account during the
%% resolution of delegated code, add an additional EIP-2929 `COLD_ACCOUNT_READ_COST`
%% cost of 2600 gas to the normal cost and add the account to `accessed_addresses`.
%% Otherwise, assess a `WARM_STORAGE_READ_COST` cost of 100."
%%
%% So the term is EIP-2929's *account* access cost, warmed or not, and it is
%% **additional to** the call's own price rather than part of it -- which is why it
%% is a separate function and not another arm of `call_cost/3`.
%%
%% **Zero before Berlin.** The warm/cold split is EIP-2929's and the EIP quotes its
%% figures, so there is no such cost at an earlier fork. It is unreachable in
%% practice -- a delegation indicator can only be written by a type-4 transaction,
%% which `tx_type_available/2' refuses before Prague -- and zero is the honest
%% answer rather than a figure invented for a case that cannot arise.
-spec delegation_resolution_cost(atom(), boolean()) -> non_neg_integer().
delegation_resolution_cost(Fork, Warm) ->
    case at_least(Fork, berlin) of
        false -> 0;
        true ->
            case Warm of
                true -> 100;
                false -> cold_account_access_cost()
            end
    end.

%% Does this opcode's price depend on what this frame has already touched?
%%
%% True for the account and slot accessors and for the CALL family. False for
%% everything else, including SSTORE: SSTORE's price is entirely variable too, but
%% it is not in this table at all (its base is a bare 0), so calling it
%% "access-sensitive" here would promise a price that does not exist. SSTORE is
%% net-metered in the interpreter and is documented as not implemented.
-spec access_sensitive(integer()) -> boolean().
access_sensitive(16#31) -> true;   % BALANCE
access_sensitive(16#3B) -> true;   % EXTCODESIZE
access_sensitive(16#3C) -> true;   % EXTCODECOPY
access_sensitive(16#3F) -> true;   % EXTCODEHASH
access_sensitive(16#54) -> true;   % SLOAD
access_sensitive(16#F1) -> true;   % CALL
access_sensitive(16#F2) -> true;   % CALLCODE
access_sensitive(16#F4) -> true;   % DELEGATECALL
access_sensitive(16#FA) -> true;   % STATICCALL
access_sensitive(_Op) -> false.

%% The part of an opcode's price that does not depend on what this frame has
%% already touched, and which the machine loop can therefore charge before the
%% opcode runs.
%%
%% Zero for the access-sensitive opcodes, and `base_gas_cost/3' for the rest --
%% which is the whole of it, since the table already carries every opcode's
%% constant price and the interpreter's own copy of that table is gone.
-spec constant_cost(integer(), atom()) -> non_neg_integer().
constant_cost(Op, Fork) when is_integer(Op), is_atom(Fork) ->
    case access_sensitive(Op) of
        true -> 0;
        false -> base_gas_cost(Op, Fork, #{})
    end;
constant_cost(_Op, _Fork) ->
    0.

%% The whole price of an access-sensitive opcode, warm or cold.
%%
%% `Args' carries the facts only the caller knows: `warm => boolean', whether this
%% frame has already touched the target. The fork decides which price regime
%% applies; the opcode supplies both figures within the chosen regime.
-spec access_cost(integer(), atom(), map()) -> non_neg_integer().
access_cost(Op, Fork, Args) when is_map(Args) ->
    {Legacy, Cold} = access_prices(Op),
    case Op of
        %% SLOAD is the one opcode whose *non-Berlin* price is not a constant, so the
        %% table's second element cannot hold it. It was 200 at every fork, which is
        %% right for exactly one span: EIP-150 takes it 50 -> 200 at Tangerine Whistle
        %% and EIP-1884 takes it 200 -> 800 at Istanbul. So a Frontier SLOAD cost a
        %% third of what it should and an Istanbul one 400 too little.
        16#54 ->
            access_cost_sload(Fork, Args);
        _ ->
            case at_least(Fork, berlin) of
                false ->
                    Legacy;
                true ->
                    case maps:get(warm, Args, false) of
                        true -> 100;
                        false -> Cold
                    end
            end
    end;
access_cost(_Op, _Fork, _Args) ->
    0.

access_cost_sload(Fork, Args) ->
    case at_least(Fork, berlin) of
        false ->
            sload_gas(Fork);
        true ->
            case maps:get(warm, Args, false) of
                true -> 100;
                false -> ?COLD_SLOAD_COST
            end
    end.

%% SLOAD_GAS, and it is not one number.
%%
%% EIP-150, in its own table of what it changed: "Increase the gas cost of SLOAD to
%% 200 (from 50)." EIP-1884, likewise: "The SLOAD (0x54) operation changes from 200
%% to 800 gas." EIP-2929 then makes it the warm/cold pair from Berlin, and the cold
%% figure is 2100.
%%
%% So: 50 at Frontier through the DAO fork, 200 from Tangerine Whistle through
%% Byzantium, and 800 from Istanbul -- which is EIP-1884's Istanbul, and the figure
%% EIP-2200 quotes as the "old" value when it sets 800 again at Berlin. The three
%% numbers are the three EIPs' and not a recollection.
-spec sload_gas(atom()) -> non_neg_integer().
sload_gas(Fork) when is_atom(Fork) ->
    case at_least(Fork, istanbul) of
        true -> 800;
        false ->
            case at_least(Fork, tangerine) of
                true -> 200;
                false -> 50
            end
    end;
sload_gas(_Fork) ->
    200.

%% The CALL family: cold/warm access cost plus, for a value-bearing call, the
%% 9000 gas stipend (EIP-161) and the 25000 new-account cost (EIP-161).
%% The CALL family's whole price: the access term plus EIP-161's two optional ones.
%%
%% Keyed by opcode so DELEGATECALL and STATICCALL get the same access figure as CALL
%% and CALLCODE without the caller having to say which family it is in.
%%
%% The two optional terms are gated on **Spurious Dragon**, not Berlin. They are
%% EIP-161's -- the 9000 for a value transfer and the 25000 for an account that did
%% not exist -- and Berlin is two forks later. This gated them on Berlin, so a
%% Spurious-Dragon-to-Byzantium CALL with value paid no 9000 and no 25000, and a
%% Homestead-to-Tangerine one paid neither while still being charged the EIP-150
%% access cost the same function computes. The gate was never exercised, because
%% nothing called this function before now.
-spec call_cost(integer(), atom(), map()) -> non_neg_integer().
call_cost(Op, Fork, Args) when is_map(Args) ->
    Access = access_cost(Op, Fork, Args),
    case at_least(Fork, spurious_dragon) of
        false ->
            Access;
        true ->
            ValueGas = case maps:get(value_transfer, Args, false) of
                true -> 9000;
                false -> 0
            end,
            NewAccountGas = case maps:get(new_account, Args, false) of
                true -> 25000;
                false -> 0
            end,
            Access + ValueGas + NewAccountGas
    end;
call_cost(_Op, _Fork, _Args) ->
    0.

account_creation_cost(_Fork) -> 32000.

%% **EIP-160**, quoted: "increase the gas cost of EXP from 10 + 10 per byte in the
%% exponent to 10 + 50 per byte in the exponent." Spurious Dragon, block 2675000.
%%
%% This is the whole EXP rule that is fork-dependent. The constant 10 that
%% `base_gas_cost(16#0A, _, _) -> 10' already charges is right at every fork, so it
%% is not repeated here and only the per-byte coefficient lives in this module --
%% the same split `sload_gas/1' and the refund cap use.
-spec exp_byte_cost(atom()) -> pos_integer().
exp_byte_cost(Fork) when is_atom(Fork) ->
    case at_least(Fork, spurious_dragon) of
        true -> 50;
        false -> 10
    end.

%% SELFDESTRUCT's base price, at every fork. EIP-2929's extra term lives in
%% `selfdestruct_access_cost/2' below, because it is the one price that cannot be
%% decided without knowing whether the beneficiary is warm.
selfdestruct_cost(_Fork) -> 5000.

%% **EIP-2929's SELFDESTRUCT term, in the EIP's own words:**
%%
%%   "If the ETH recipient of a SELFDESTRUCT is not in accessed_addresses
%%    (regardless of whether or not the amount sent is nonzero), charge an
%%    additional COLD_ACCOUNT_ACCESS_COST on top of the existing gas costs, and
%%    add the ETH recipient to the set."
%%
%%   "Note: SELFDESTRUCT does not charge a WARM_STORAGE_READ_COST in case the
%%    recipient is already warm, which differs from how the other call-variants
%%    work. The reasoning behind this is to keep the changes small, a
%%    SELFDESTRUCT already costs 5K and is a no-op if invoked more than once."
%%
%% **The warm figure is therefore 0, not 100**, and that is the one place in this
%% module whose answer is not `access_cost/3'. Copying `call_cost/3''s shape here
%% would charge 100 to every warm SELFDESTRUCT; `access_prices/1` has no `16#FF'
%% row to produce even a correct cold figure, so a copy would fail on a function
%% clause rather than quietly. Hence a separate function rather than another row.
%%
%% "regardless of whether or not the amount sent is nonzero" is load-bearing too,
%% and is why the caller passes nothing about the value: a SELFDESTRUCT that
%% sends nothing to a cold address is still 2600, and gating this on the transfer
%% would make a no-op selfdestruct cheap -- which is the cheapest possible
%% griefing primitive if it were the rule.
-spec selfdestruct_access_cost(atom(), map()) -> non_neg_integer().
selfdestruct_access_cost(Fork, Args) when is_atom(Fork), is_map(Args) ->
    case at_least(Fork, berlin) of
        false ->
            0;
        true ->
            case maps:get(warm, Args, false) of
                true -> 0;
                false -> cold_account_access_cost()
            end
    end.

%% ---------------------------------------------------------------------------
%% SSTORE net metering (EIP-2200)
%% ---------------------------------------------------------------------------
%% ---------------------------------------------------------------------------
%% This is the one price that cannot be derived from the frame alone. Every other
%% opcode's cost is a function of the opcode, the fork, and what the frame has
%% already touched. SSTORE's depends on a third thing the frame does not carry:
%% the value the slot held **at the start of the transaction**, as opposed to the
%% value it holds now. EIP-2200's whole point is that the difference between those
%% two is what distinguishes a first write from a rewrite.
%%
%% The interpreter supplies all three values and this function supplies the
%% arithmetic, because the arithmetic is where the fork lives.

%% What a transaction must have left for SSTORE to proceed at all. EIP-2200
%% clause (0): at or below the stipend, fail the frame. It exists so a frame
%% cannot be left with enough gas to keep executing but not enough to pay for
%% its own writes -- the reentrancy window EIP-1283 opened and EIP-2200 closed.
%%
%% Zero before Berlin, because the sentry is EIP-2200's and there is nothing to
%% check against. The comparison is `gas =< Sentry', so a sentry of 0 would halt
%% every SSTORE; callers must skip the check entirely rather than compare against
%% it. See `sstore_supported/1`.
-spec sstore_sentry(atom()) -> non_neg_integer().
sstore_sentry(Fork) when is_atom(Fork) ->
    case at_least(Fork, berlin) of
        true -> 2300;
        false -> 0
    end;
sstore_sentry(_Fork) -> 0.

%% Is SSTORE's schedule implemented at this fork?
%%
%% Berlin and later only, and the boundary is not arbitrary. There are **three**
%% pre-Berlin schedules, not one: the flat rule (20000 to create a slot, 5000 to
%% reset one, 15000 back for clearing) from Frontier to Byzantium; EIP-1283's net
%% metering at Constantinople, which is a *different* schedule and not a
%% restatement of the flat one -- its title is "Net gas metering for SSTORE without
%% dirty maps", and the absence of a dirty map is exactly what EIP-2200 later
%% introduced; and then Petersburg, which reverted Constantinople and so restored
%% the flat rule. A single pre-Berlin price would be right for two of those three
%% spans and wrong for the third, and wrong *only* at Constantinople is the kind of
%% gap that is never noticed, because nothing executes Constantinople blocks on
%% this node and a test that exercised the flat rule at both neighbours would pass.
%%
%% So pre-Berlin is refused rather than priced, and the caller turns that into an
%% `unsupported' error, which `eth_call' answers with an upstream fallback. A
%% fabricated number would be worse than another node's answer: this one would be
%% indistinguishable from a correct one.
%% SSTORE is supported at every fork **except Constantinople**.
%%
%% This used to answer `at_least(Fork, berlin)', so every pre-Berlin fork was
%% refused, and -- much worse than a gap -- the refusal was *executed*: the halt was
%% recorded as an ordinary failed transaction, charged its whole gas limit, and the
%% block's state root was committed. That was 48 of the 266 committed fixtures. The
%% refusal is still correct for Constantinople and for nothing else, and the reason is
%% below.
-spec sstore_supported(atom()) -> boolean().
sstore_supported(constantinople) ->
    false;
sstore_supported(Fork) when is_atom(Fork) ->
    %% An unrecognised fork is **refused** the rule, not granted it, which is the
    %% direction this module takes everywhere else. The catch is that `frontier' shares
    %% rank 0 with every unknown atom -- it is the bottom of the order by definition --
    %% so `fork_rank(Fork) > 0' on its own refuses Frontier as well. It did, and a test
    %% said so. `frontier' is 0, not 1; I read it as 1 twice.
    %%
    %% My first version was plain `Fork =/= constantinople', which granted the rule at
    %% *every* unknown fork: `sstore_supported(no_such_fork)' answered `true'. Between
    %% those two, the two facts that matter are kept apart -- Frontier is a fork,
    %% `no_such_fork' is not -- and neither version is a list of forks, which would be a
    %% second copy of the thing this module exists to hold in one place.
    fork_rank(Fork) > 0 orelse Fork =:= frontier;
sstore_supported(_Fork) ->
    false.

%% ---------------------------------------------------------------------------
%% Transaction-type availability
%% ---------------------------------------------------------------------------
%% A typed transaction is a *new wire format*, so unlike an opcode it is not a
%% cheap instruction that a block could execute anyway: a node that decoded a
%% Berlin block carrying a type-2 transaction would be decoding bytes the fork it
%% is executing never defined. The fork schedule therefore gates the *type*, and
%% `eth_tx:validate/2' asks this rather than deciding it inline, for the reason
%% `opcode_exists/2' exists: the gas table says what a thing costs once it is
%% there, and says nothing about whether it is there yet.
%%
%% Each activation is the EIP's own, and they are not the fork that introduced the
%% *feature* the type carries. Type 1 is EIP-2930 (Berlin), type 2 is EIP-1559
%% (London), type 3 is EIP-4844 (Cancun), and type 4 is EIP-7702 (Prague).
%%
%% `legacy' is the type every fork has and is therefore always available; it is
%% written as a clause rather than a catch-all so that a type this fork table has
%% never heard of answers `false' instead of inheriting legacy's answer, which is
%% the mistake a catch-all makes here.
%%
%% The corpus found the absence of this as a validator that **accepted** an
%% EIP-1559 transaction inside a Berlin block. `validate/2' checked only that the
%% type was one it could decode, so a type-2 transaction at a pre-London fork
%% validated -- and a block containing one would be accepted rather than refused
%% whole. Admitting something invalid is the worse of the two directions: a node
%% that refuses a valid transaction loses a transaction, whereas a node that
%% accepts an invalid one agrees with nobody about the chain.
%%
%% The activations are held once, in `introduced_tx_type/1', and the availability
%% question is derived from them. A second hand-written list of the same four forks
%% would be two copies of one fact, and this module's own history is that two copies
%% drift: `eth_evm:base_cost/1' was a fork-free duplicate of the gas table, and the
%% two had come to disagree about how they grouped four sets of constants.
%% ---------------------------------------------------------------------------
%% ModExp (0x05): EIP-198's price, then EIP-2565's
%% ---------------------------------------------------------------------------
%% ModExp is the one precompile whose price is a formula rather than a figure, and
%% the formula changed once. This node implemented a mixture that matched no fork at
%% all: EIP-198's multiplication complexity and its divisor of 20, with EIP-2565's
%% floor of 200 -- and no Berlin switch, so Berlin's divisor of 3 and its `words**2'
%% complexity were missing entirely.
%%
%% The 200 floor is EIP-2565's, and EIP-198's text has no minimum at all: "Consumes
%% floor(mult_complexity(...) * max(ADJUSTED_EXPONENT_LENGTH, 1) / GQUADDIVISOR) gas"
%% with GQUADDIVISOR = 20. So a small ModExp call at Byzantium was overcharged, and
%% every ModExp call at Berlin was overcharged by up to a factor of six.
%% ---------------------------------------------------------------------------
%% EIP-150: the call gas cap and the stipend
%% ---------------------------------------------------------------------------
%% EIP-150 (Tangerine Whistle) did two things to the gas a child frame receives, and
%% **the node applied both at every fork**, including the four before it. Its own text
%% gives the rule it replaced, which is what makes the earlier behaviour derivable
%% rather than a matter of recall:
%%
%%     Define "all but one 64th" of N as N - floor(N / 64).
%%
%%     ... if a call asks for more gas than the maximum allowed amount ... do not
%%     return an OOG error; instead, if a call asks for more gas than all but one
%%     64th of the maximum allowed amount, call with all but one 64th ...
%%     CREATE only provides all but one 64th of the parent gas to the child call.
%%
%%     That is, substitute:
%%
%%     extra_gas = (not ext.account_exists(to)) * opcodes.GCALLNEWACCOUNT +
%%                 (value > 0) * opcodes.GCALLVALUETRANSFER
%%     if compustate.gas < gas + extra_gas:
%%         return vm_exception('OUT OF GAS', needed=gas+extra_gas)
%%     submsg_gas = gas + opcodes.GSTIPEND * (value > 0)
%%
%% The `substitute' block is the code as it stood **before** the EIP, and it has no
%% `all but one 64th' in it: a call was given whatever the parent had left, and asking
%% for more was an out-of-gas error. The cap and the stipend therefore both arrive with
%% Tangerine Whistle and neither existed before it.
-spec all_but_one_64th(atom()) -> boolean().
all_but_one_64th(Fork) when is_atom(Fork) -> at_least(Fork, tangerine);
all_but_one_64th(_Fork) -> false.

%% EIP-150's GSTIPEND, 2300, and it is added when **value moves** -- `submsg_gas =
%% gas + opcodes.GSTIPEND * (value > 0)`. I read this as backwards when I first looked
%% at the interpreter, on the reasoning that a stipend exists to let a callee do the
%% cheap thing a value transfer can already afford. The EIP says the opposite and the
%% interpreter was already right; the reasoning that produced the doubt is what a
%% recollection is worth.
-spec call_stipend(atom()) -> non_neg_integer().
call_stipend(Fork) when is_atom(Fork) ->
    case at_least(Fork, tangerine) of
        true -> ?CALL_STIPEND;
        false -> 0
    end;
call_stipend(_Fork) -> 0.

-spec modexp_cost(atom()) -> {non_neg_integer(), non_neg_integer()}.
modexp_cost(Fork) ->
    case at_least(Fork, berlin) of
        true -> {?MOD_EXP_GQUADDIVISOR_BERLIN, ?MOD_EXP_MIN_BERLIN};
        false -> {?MOD_EXP_GQUADDIVISOR_BYZANTIUM, 0}
    end.

%% The multiplication complexity, which is a different function on each side of
%% Berlin and not a simplification of one another.
%%
%% EIP-198's own text:
%%
%%   def mult_complexity(x):
%%       if x <= 64: return x ** 2
%%       elif x <= 1024: return x ** 2 // 4 + 96 * x - 3072
%%       else: return x ** 2 // 16 + 480 * x - 199680
%%
%% EIP-2565 replaced all three branches with `words**2', where
%% `words = math.ceil(max_length / 8)`. Berlin did not tune the piecewise formula, it
%% discarded it, and carrying the piecewise one across Berlin is not a conservative
%% choice -- it is a different number.
-spec modexp_complexity(atom(), non_neg_integer()) -> non_neg_integer().
modexp_complexity(Fork, Max) ->
    case at_least(Fork, berlin) of
        true ->
            Words = (Max + 7) div 8,
            Words * Words;
        false when Max =< 64 ->
            Max * Max;
        false when Max =< 1024 ->
            Max * Max div 4 + 96 * Max - 3072;
        false ->
            Max * Max div 16 + 480 * Max - 199680
    end.

%% ---------------------------------------------------------------------------
%% Precompiles: which contract is where, and what it costs
%% ---------------------------------------------------------------------------
%% A precompile's *address* is fork-dependent, and so is its price, and this module
%% held neither. Two consequences, both on forks this node's schedule covers:
%%
%%   - The **layout** was Istanbul's at every fork. 0x08 is the pairing check from
%%     Byzantium and stays there; 0x09 is blake2f from Istanbul (EIP-152) and is
%%     *nothing* before it; 0x0A is EIP-4844's point evaluation from Cancun. So on a
%%     Byzantium block the node ran blake2f at 0x09, where the specification has no
%%     contract at all. That is not a gas difference: a CALL to an address with no
%%     code succeeds, returns nothing and runs empty code, and one that runs blake2f
%%     does not.
%%   - The **prices** were Istanbul's at every fork. EIP-1108's table is the
%%     Istanbul column; the pre-Istanbul figures are EIP-196's and EIP-197's.
%%     ECADD at 150 rather than 500 is not a rounding difference, and on mainnet it
%%     applies to every block from genesis to 9,069,000.
%%
%% `precompile_at/2' and `bn128_cost/2' are separate questions and stay separate
%% functions. A single "what does address N cost" function cannot answer either one
%% correctly on its own: the cost depends on the word count of the input, which the
%% precompile knows and this table does not, and it depends on the layout, which is
%% the other question.
-spec precompile_at(atom(), integer()) -> atom() | undefined.
precompile_at(_Fork, 1) -> ecrecover;
precompile_at(_Fork, 2) -> sha256;
precompile_at(_Fork, 3) -> ripemd160;
precompile_at(_Fork, 4) -> identity;
precompile_at(_Fork, 5) -> modexp;
%% EIP-196 (Byzantium) added the alt_bn128 arithmetic. Before Byzantium 0x06 and
%% 0x07 are ordinary accounts, exactly as 0x09 is before Istanbul.
precompile_at(Fork, 6) -> introduced_at(Fork, byzantium, ecadd);
precompile_at(Fork, 7) -> introduced_at(Fork, byzantium, ecmul);
%% 0x08 is the alt_bn128 pairing check from Byzantium onward and **stays** there
%% across Istanbul. I wrote this the other way round first -- on the recollection
%% that Istanbul swapped 0x08 and 0x09, giving blake2f 0x08 and the pairing check
%% 0x09 -- and that was wrong. The committed corpus says so directly:
%%
%%   - `byzantium/eip197_ec_pairing/test_gas_costs.json` contains a contract whose
%%     code is `PUSH1 8 ... CALL`, so the pairing check is at 0x08 at Byzantium.
%%   - `istanbul/eip152_blake2/test_blake2_precompile_delegatecall.json` contains
%%     `PUSH1 9, PUSH1 1, DELEGATECALL`, so blake2f is at 0x09 at Istanbul.
%%
%% Two fixtures, one at each fork, and no swap between them. Had the recollection
%% stood, the fix would have swapped a correct layout for a wrong one while the commit
%% message claimed to repair it -- which is why the answer came from the corpus and
%% not from an EIP page, and why the two addresses' history is recorded here at all.
%% Gated like every other arrival rather than written as a constant. An unrecognised
%% fork ranks as ancient everywhere else in this module, so a bare `8 -> ecpairing'
%% would make 0x08 the one address an unknown fork *can* reach -- and that is the same
%% mistake `opcode_exists/2' exists to avoid, in a different table.
precompile_at(Fork, 8) -> introduced_at(Fork, byzantium, ecpairing);
precompile_at(Fork, 9) -> introduced_at(Fork, istanbul, blake2f);
precompile_at(Fork, 10) -> introduced_at(Fork, cancun, point_evaluation);
precompile_at(_Fork, _) -> undefined.

%% EIP-4844 (Cancun) added the point evaluation at 0x0A. Before Cancun there is
%% nothing there.
introduced_at(Fork, At, What) ->
    case at_least(Fork, At) of
        true -> What;
        false -> undefined
    end.

%% Every address this table recognises at `Fork', as a list of 20-byte addresses.
%%
%% EIP-2929 says `accessed_addresses' is initialised to include "the set of all
%% precompiles", and the only way to answer that without a second copy of the layout
%% is to ask the layout. Asking it as a *list* is what forces the question; the caller
%% needs a set and the table has a function of one address.
%%
%% The bound is 10 because that is the last address named above and the last clause is
%% a catch-all, so the table cannot recognise a higher one at any fork. The bound lives
%% here, beside the layout it bounds, and not in the caller: a bound in a caller is the
%% same list of addresses wearing a different hat, and it would still be right when
%% the layout moved. `no_precompile_above_ten_is_the_highest_address_test' is the pin
%% that makes the two statements stay the same statement.
-spec precompile_addresses(atom()) -> [binary()].
precompile_addresses(Fork) when is_atom(Fork) ->
    %% **20 bytes, not one.** `precompile_at/2' is keyed by the address's last byte,
    %% which is convenient, and the list it produces is a list of *addresses*, which
    %% are 160 bits everywhere in the EVM. My first version built `<<N>>' -- one byte
    %% -- and every seed was a key no 160-bit address could ever equal, so the
    %% interpreter started with an access list that was present, correctly shaped, and
    %% inert. The corpus did not move, which is the part worth keeping: a warm set that
    %% is seeded under the wrong key looks exactly like one that is not seeded, and the
    %% two are indistinguishable from the outside.
    [<<0:152, N:8>> || N <- lists:seq(1, ?HIGHEST_PRECOMPILE),
                      precompile_at(Fork, N) =/= undefined];
precompile_addresses(_Fork) ->
    [].

%% The alt_bn128 arithmetic costs, as `{Base, PerUnit}'.
%%
%% The post-Istanbul figures are EIP-1108's own table:
%%
%%   Contract       Address   Current Gas Cost        Updated Gas Cost
%%   ECADD          0x06      500                      150
%%   ECMUL          0x07      40 000                   6 000
%%   Pairing check  0x08      80 000 * k + 100 000     34 000 * k + 45 000
%%
%% and the "Current" column is EIP-196's and EIP-197's, which is what applies before
%% Istanbul. `PerUnit' is per pair for the pairing check and zero elsewhere.
-spec bn128_cost(atom(), ecadd | ecmul | ecpairing) -> {integer(), integer()}.
bn128_cost(Fork, ecadd) -> istanbul_from(Fork, {500, 0}, {150, 0});
bn128_cost(Fork, ecmul) -> istanbul_from(Fork, {40000, 0}, {6000, 0});
bn128_cost(Fork, ecpairing) ->
    istanbul_from(Fork, {100000, 80000}, {45000, 34000}).

istanbul_from(Fork, Before, From) ->
    case at_least(Fork, istanbul) of
        true -> From;
        false -> Before
    end.

%% ---------------------------------------------------------------------------
%% EIP-7702: the authorization list
%% ---------------------------------------------------------------------------
%% A type-4 transaction carries a list of authorization tuples, and the EIP's
%% "Gas Costs" section prices them:
%%
%%   The intrinsic cost of the new transaction is inherited from EIP-2930 ...
%%   Additionally, add a cost of PER_EMPTY_ACCOUNT_COST * authorization list
%%   length. The transaction sender will pay for all authorization tuples,
%%   regardless of validity or duplication.
%%
%% with PER_EMPTY_ACCOUNT_COST = 25000. So the charge is 25,000 per tuple and it
%% does not depend on whether a tuple turns out to be usable -- "the sender pays
%% for all of them" is the EIP's wording and the reason the price is a function of
%% the list's *length* rather than of anything recovered from it.
%%
%% (PER_AUTH_BASE_COST = 12500 is the EIP's other parameter. It is the *processing*
%% cost of recovering and applying one tuple, metered in the state transition, and
%% it is **not** implemented here. It is named so that its absence is a named
%% absence rather than an oversight; see TASKS.md.)
%%
%% Zero before Prague, which makes the one caller a no-op rather than a branch.
-spec set_code_auth_cost(atom()) -> non_neg_integer().
set_code_auth_cost(Fork) when is_atom(Fork) ->
    case at_least(Fork, prague) of
        true -> ?PER_EMPTY_ACCOUNT_COST;
        false -> 0
    end;
set_code_auth_cost(_Fork) -> 0.

%% EIP-7702 step 7: "Add `PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST` gas to the
%% global refund counter if `authority` is not empty."
%%
%% **The difference, not the value.** The EIP states it as a subtraction of two named
%% parameters and the subtraction is the specification -- an authorization by an
%% account that already exists costs half of one by an account that did not, and
%% that relationship is the thing a future revision would change. Writing `12500`
%% here would keep the number and lose the rule.
%%
%% **Zero before Prague**, for the same reason `set_code_auth_cost/1` is: no
%% type-4 transaction can be valid earlier, so the figure is unreachable there and
%% zero is the honest answer rather than an invented one.
-spec set_code_refund(atom()) -> non_neg_integer().
set_code_refund(Fork) when is_atom(Fork) ->
    case at_least(Fork, prague) of
        true -> ?PER_EMPTY_ACCOUNT_COST - ?PER_AUTH_BASE_COST;
        false -> 0
    end;
set_code_refund(_Fork) -> 0.

-spec tx_type_available(atom(), atom()) -> boolean().
tx_type_available(legacy, Fork) when is_atom(Fork) -> true;
tx_type_available(Type, Fork) when is_atom(Fork) ->
    case introduced_tx_type(Type) of
        undefined -> false;
        At -> at_least(Fork, At)
    end;
tx_type_available(_Type, _Fork) -> false.

%% Every transaction type, with the fork that introduced it. `legacy' is absent on
%% purpose: it is the type the wire format had before types existed, so it has no
%% introducing fork, and `tx_type_available/2' answers for it without asking.
-spec introduced_tx_type(atom()) -> atom() | undefined.
introduced_tx_type(eip2930) -> berlin;
introduced_tx_type(eip1559) -> london;
introduced_tx_type(eip4844) -> cancun;
introduced_tx_type(eip7702) -> prague;
introduced_tx_type(_Type) -> undefined.

%% EIP-3529 (London) replaces SSTORE_CLEARS_SCHEDULE -- 15000 as EIP-2200 defined
%% it -- with `SSTORE_RESET_GAS + ACCESS_LIST_STORAGE_KEY_COST', which is
%% (5000 - 2100) + 1900 = 4800. EIP-2929 is what put SSTORE_RESET_GAS at 2900 in
%% the first place, so the sum is over the *Berlin* reset figure and not over 5000.
%% The code-deposit cost and the maximum deployable code size, which are two
%% different things that are constantly confused because EIP-170 changed one of
%% them.
%%
%% `code_deposit_cost/1' is the yellow paper's `G_codedeposit', **200 per byte**,
%% and it is 200 at every fork in this table: no EIP has ever changed it. EIP-2
%% did not introduce it and did not change it -- EIP-2 introduced the *consequence*
%% (item 3: "If contract creation does not have enough gas to pay for the final gas
%% fee for adding the contract code to the state, the contract creation fails (i.e.
%% goes out-of-gas) rather than leaving an empty contract"), which is why before
%% Homestead the gas went and the deployment did not, and from Homestead the
%% deployment fails as well. `max_code_size/1' is EIP-170's `MAX_CODE_SIZE', 0x6000
%% = 24576, and EIP-170 is Spurious Dragon.
%%
%% So the pair is: 200/byte always, and a 24,576-byte cap only from Spurious Dragon.
%% Before it there is no cap, only a price -- which is why a 10,000-byte deployment
%% is legitimate at any fork as long as the caller can pay 2,000,000 gas, and why
%% `max_code_size/1' answers `infinity' rather than 24576 below Spurious Dragon.
-spec code_deposit_cost(atom()) -> non_neg_integer().
code_deposit_cost(Fork) when is_atom(Fork) ->
    %% One number, deliberately. It is the yellow paper's, and the module comment
    %% on `access_prices/1' records what happens to a table that assumes a figure
    %% cannot move: SLOAD's was 200 at every fork and that was right for one span of
    %% three. This one is pinned by the corpus instead -- `create_deposit_oog' deploys
    %% 10,000 bytes into a frame holding under 1,000,000 gas, and the fixture's
    %% expected spend is the whole allowance, which is what "2,000,000 gas of deposit
    %% out of 934,172 available" has to look like.
    200;
code_deposit_cost(_Fork) ->
    200.

-spec max_code_size(atom()) -> pos_integer() | infinity.
max_code_size(Fork) when is_atom(Fork) ->
    case at_least(Fork, spurious_dragon) of
        true -> ?MAX_CODE_SIZE;
        false -> infinity
    end;
max_code_size(_Fork) ->
    infinity.

%% EIP-3860 (Shanghai): `MAX_INITCODE_SIZE = 2 * MAX_CODE_SIZE`, so **49,152** and not a
%% number of its own. Derived from `?MAX_CODE_SIZE' rather than transcribed, because the
%% relation is the EIP's and a transcribed 49,152 would be a constant that could not be
%% checked against the one it is defined in terms of. `eth_fork_schedule` already held
%% EIP-3860's *price* half -- `initcode_word_cost/1' -- and not its *limit*, so the fork
%% charged a per-word cost for initcode that the specification says may not exist at that
%% size at all.
%%
%% `infinity' below Shanghai, for the same reason `max_code_size/1' answers `infinity'
%% below Spurious Dragon: there was no limit, and answering 49,152 below Shanghai would
%% refuse transactions that are valid on the chain.
-spec max_initcode_size(atom()) -> pos_integer() | infinity.
max_initcode_size(Fork) when is_atom(Fork) ->
    case at_least(Fork, shanghai) of
        true -> 2 * ?MAX_CODE_SIZE;
        false -> infinity
    end;
max_initcode_size(_Fork) ->
    infinity.

%% EIP-3607 (London): a transaction whose sender has deployed code is invalid. Named for
%% the rule rather than the EIP number, as `code_deposit_cost/1' and `max_code_size/1'
%% are -- what matters to a caller is whether the sender must be an externally owned
%% account, and that is a fact about the fork.
%%
%% There is no constant here, which is unusual for this module and deliberate: EIP-3607
%% adds a *refusal*, not a price, and a function that answered a number would invite
%% exactly the arithmetic the rule does not do.
-spec sender_must_be_eoa(atom()) -> boolean().
sender_must_be_eoa(Fork) when is_atom(Fork) ->
    at_least(Fork, london);
sender_must_be_eoa(_Fork) ->
    true.

%% EIP-2929's "SSTORE changes", which is two instructions and the node did one of them.
%%
%%   When calling `SSTORE', check if the `(address, storage_key)' pair is in
%%   `accessed_storage_keys'. If it is not, charge an **additional** `COLD_SLOAD_COST'
%%   gas, and add the pair to `accessed_storage_keys'. Additionally, modify the
%%   parameters defined in EIP-2200 as follows:
%%
%%     SLOAD_GAS        : 800 -> = WARM_STORAGE_READ_COST
%%     SSTORE_RESET_GAS : 5000 -> 5000 - COLD_SLOAD_COST
%%
%% "The other parameters defined in EIP 2200 are unchanged."
%%
%% The second half -- the parameter rewrites -- is what `sstore_cost/4' does, and the
%% first half was missing: the price came from `sstore_cost/4' and nothing added the
%% additional 2,100. So every **first** touch of a storage slot at Berlin and later
%% cost 2,100 too little, and the *second* write to the same slot was right, which is
%% a fingerprint worth naming because it is invisible in any test that writes a slot
%% twice. It is the largest single divergence in the corpus: 40 of the 217 fixtures
%% that carry a comparable gas figure, all at exactly -2,100.
-spec sstore_cold_cost(atom(), boolean()) -> non_neg_integer().
sstore_cold_cost(Fork, Warm) when is_atom(Fork), is_boolean(Warm) ->
    case at_least(Fork, berlin) andalso Warm =:= false of
        true -> ?COLD_SLOAD_COST;
        false -> 0
    end;
sstore_cold_cost(_Fork, _Warm) ->
    0.

-spec clears_schedule(atom()) -> integer().
clears_schedule(Fork) when is_atom(Fork) ->
    case at_least(Fork, london) of
        true -> 4800;
        false -> 15000
    end;
clears_schedule(_Fork) -> 15000.

%% The price of one SSTORE and the refund it earns, as EIP-2200 (with EIP-2929's
%% figures) and EIP-3529's refund define them.
%%
%% The decision tree, with the clause numbers from the EIP so each arm can be
%% checked against it:
%%
%%   (1.)   current == new                                  -> SLOAD_GAS, no refund
%%   (2.)   original == current
%%     (2.1.1.)  original == 0                              -> SSTORE_SET_GAS
%%     (2.1.2.)  otherwise                                  -> SSTORE_RESET_GAS,
%%                                                            + clears if new == 0
%%   (2.2.) original /== current (the slot is dirty)        -> SLOAD_GAS
%%     (2.2.1.)  original /= 0
%%       (2.2.1.1.)  current == 0                          -> -clears
%%       (2.2.1.2.)  new == 0                              -> +clears
%%     (2.2.2.)  original == new
%%       (2.2.2.1.)  original == 0                          -> +(SET - SLOAD)
%%       (2.2.2.2.)  otherwise                              -> +(RESET - SLOAD)
%%
%% `Original' is the value at the start of the transaction and `Current' the value
%% now, so "dirty" is simply `Original =/= Current' -- EIP-2200 needs no dirty flag
%% because the two values carry the same information. That is worth stating
%% because the obvious implementation adds one, and a flag that can disagree with
%% the values it summarises is a second source of truth.
%%
%% 2.2.1.1 and 2.2.1.2 are written as two separate contributions rather than an
%% if/else. They cannot both fire -- in arm (2.2.) a zero `Current' implies a
%% non-zero `New', since a zero-to-zero write was handled at (1.) -- so the two
%% forms agree, and the separate form is the one that matches the EIP's text.
-spec sstore_cost(atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ->
          {non_neg_integer(), integer()}.
sstore_cost(Fork, Original, Current, New)
  when is_atom(Fork), is_integer(Original), is_integer(Current), is_integer(New) ->
    case sstore_supported(Fork) of
        false ->
            %% Refused, so there is no price. This is the only fork that reaches it,
            %% because the `false' branch below prices every other pre-Berlin fork --
            %% and it is here so a caller that forgets `sstore_supported/1' gets the
            %% pre-fork answer rather than a plausible number for a rule this node
            %% does not implement.
            {0, 0};
        true ->
    case at_least(Fork, berlin) of
        false ->
            %% **The flat rule**, which is the yellow paper's and which Petersburg put
            %% back. EIP-2200 states the figures it inherited:
            %%
            %%     Define variables SLOAD_GAS, SSTORE_SET_GAS, SSTORE_RESET_GAS and
            %%     SSTORE_CLEARS_SCHEDULE. The old and new values for those variables
            %%     are:
            %%
            %%     SLOAD_GAS             : changed from 200 to 800.
            %%     SSTORE_SET_GAS        : 20000, not changed.
            %%     SSTORE_RESET_GAS      : 5000, not changed.
            %%     SSTORE_CLEARS_SCHEDULE: 15000, not changed.
            %%
            %% and the rule those figures go with is the three-case one:
            %%
            %%     if current value equals new value:            SLOAD_GAS
            %%     else if current value is zero:                SSTORE_SET_GAS
            %%     else:                                         SSTORE_RESET_GAS
            %%         and if new value is zero, add SSTORE_CLEARS_SCHEDULE to refunds
            %%
            %% Berlin's figures differ from these -- its reset is 2,900, not 5,000,
            %% because EIP-2929 folds the cold-slot access into it -- which is why
            %% this is the `false' branch and the EIP-2200 case below is the `true' one.
            %%
            %% `SLOAD_GAS' is itself fork-selected: 50 before Tangerine Whistle,
            %% 200 from it, 800 from Istanbul (EIP-150, then EIP-1884). Quoting EIP-2200's
            %% "200" alone would be right for two of the three spans.
            %%
            %% **Constantinople is the one fork this does not answer for.** EIP-1283
            %% replaced the three-case rule with net metering, and Petersburg reverted
            %% it -- so the flat rule is right for the eight other pre-Berlin forks and
            %% wrong for exactly one. `sstore_supported/1' still refuses there, and the
            %% refusal is now safe: `eth_block:run_transaction/5' answers
            %% `{error, {unpriced, What}}' rather than committing a state root the
            %% chain would not produce. No committed fixture exercises it, so this is a
            %% named gap and not a measured one.
            case Current =:= New of
                true ->
                    {sload_gas(Fork), 0};
                false ->
                    case Current of
                        0 -> {?SSTORE_SET_GAS, 0};
                        _ -> {?SSTORE_RESET_GAS, case New of
                                                 0 -> clears_schedule(Fork);
                                                 _ -> 0
                                             end}
                    end
            end;
        true ->
            case Current =:= New of
                true -> {100, 0};                                    % (1.)
                false ->
                    case Original =:= Current of
                        true -> sstore_clean(Fork, Original, New);    % (2.1.)
                        false -> sstore_dirty(Fork, Original, Current, New)  % (2.2.)
                    end
            end
    end
    end;
sstore_cost(_Fork, _Original, _Current, _New) ->
    {0, 0}.

sstore_clean(_Fork, 0, _New) ->
    {20000, 0};                                                    % (2.1.1.)
sstore_clean(Fork, _Original, New) ->
    {2900, case New =:= 0 of
               true -> clears_schedule(Fork);                      % (2.1.2.)
               false -> 0
           end}.

sstore_dirty(Fork, Original, Current, New) ->
    Clears = clears_schedule(Fork),
    Refund = clear_adjustment(Clears, Original, Current, New) +   % (2.2.1.)
             reset_adjustment(Original, New),                      % (2.2.2.)
    {100, Refund}.

%% (2.2.1.) A dirty slot that was non-zero when the transaction began, being
%% re-created or deleted again, moves the clear refund in the matching direction.
clear_adjustment(_Clears, 0, _Current, _New) ->
    0;
clear_adjustment(Clears, _Original, 0, _New) ->
    -Clears;                                                        % (2.2.1.1.)
clear_adjustment(Clears, _Original, _Current, 0) ->
    Clears;                                                         % (2.2.1.2.)
clear_adjustment(_Clears, _Original, _Current, _New) ->
    0.

%% (2.2.2.) The slot is being put back to the value the transaction found, so the
%% whole of the earlier write is undone: the difference between what that write
%% cost and what this one costs comes back.
reset_adjustment(Original, New) when New =/= Original ->
    %% 2.2.2 is guarded on `original == new', and that guard is the whole of
    %% the arm: without it a dirty write that merely changes the value to
    %% something else would refund, which is not what the EIP says. It is also
    %% the arm that misbehaves worst when dropped -- the cases that reach it are
    %% exactly the ones where a write is being undone, and a wrong `0' there is
    %% invisible because the frame still succeeds and still returns a plausible
    %% amount of gas.
    0;
reset_adjustment(0, 0) ->
    20000 - 100;                                                    % (2.2.2.1.)
reset_adjustment(_Original, _New) ->
    2900 - 100.                                                     % (2.2.2.2.)

%% ---------------------------------------------------------------------------

%% Not every fork-dependent rule is a number in a table. Some of them are a
%% question with a boolean answer -- may this frame delete an account's storage,
%% may this transaction's refunds exceed this -- and those are here, next to the
%% prices, so that "what does this fork do" is answerable from one module.

%% ---------------------------------------------------------------------------
%% EIP-7623: the calldata floor
%% ---------------------------------------------------------------------------
%% EIP-7623 raises the *floor* under a transaction's gas without raising the
%% marginal price of calldata, so that a block's size is bounded by what its
%% transactions must pay rather than by what they happen to execute. Prague.
%%
%% Its text:
%%
%%     tokens_in_calldata = zero_bytes_in_calldata + nonzero_bytes_in_calldata * 4
%%
%%     tx.gasUsed = 21000 + max(STANDARD_TOKEN_COST * tokens_in_calldata
%%                              + execution_gas_used
%%                              + isContractCreation * (32000 + INITCODE_WORD_COST
%%                                                      * words(calldata)),
%%                              TOTAL_COST_FLOOR_PER_TOKEN * tokens_in_calldata)
%%
%% with STANDARD_TOKEN_COST = 4 and TOTAL_COST_FLOOR_PER_TOKEN = 10.
%%
%% The floor term is `21000 + 10 * tokens', and everything else in the `max' is what
%% this node already charges as `intrinsic + execution'. So the whole rule is one
%% `max' on the total, and it is applied in `eth_block:run_transaction/5' where the
%% total exists. Validation is a separate clause of the EIP -- a transaction whose
%% gas limit is below the floor is invalid -- and that is `eth_tx:validate/2'.
%%
%% Two things are deliberately *not* here. The floor counts **calldata only**:
%% `tokens_in_calldata' is defined over the transaction's data and says nothing
%% about access-list items, which are priced by EIP-2930's own schedule. And it
%% does not touch the marginal price: a zero byte still costs 4 and a non-zero byte
%% still costs 16, which is what `eth_tx:intrinsic_gas/4' charges. The floor is a
%% minimum total, not a new price.
-spec calldata_floor(atom(), binary()) -> non_neg_integer().
calldata_floor(Fork, Data) when is_atom(Fork), is_binary(Data) ->
    case at_least(Fork, prague) of
        false ->
            0;
        true ->
            Zero = count_byte(0, Data, 0),
            NonZero = byte_size(Data) - Zero,
            21000 + ?TOTAL_COST_FLOOR_PER_TOKEN * (Zero + 4 * NonZero)
    end;
calldata_floor(_Fork, _Data) ->
    0.

count_byte(Byte, Bin, Acc) ->
    count_byte(Byte, Bin, Acc, byte_size(Bin)).

count_byte(_Byte, _Bin, Acc, 0) -> Acc;
count_byte(Byte, Bin, Acc, N) ->
    case binary:at(Bin, N - 1) of
        Byte -> count_byte(Byte, Bin, Acc + 1, N - 1);
        _ -> count_byte(Byte, Bin, Acc, N - 1)
    end.

%% ---------------------------------------------------------------------------
%% Rules the fork selects, as opposed to prices it supplies
%% ---------------------------------------------------------------------------
%% EIP-3529 (London) sets MAX_REFUND_QUOTIENT to 5 and caps the refund at
%% `gas_used // 5'. Before it, EIP-2200 (Berlin) capped at `gas_used // 2', and
%% the ratio is 1/2 in the EIP-3529 motivation section's own description of the
%% rule it replaces. The two are not interchangeable and the difference is not
%% small: at London a transaction may refund a fifth of what it spent rather than
%% half, so a frame that refunds the maximum comes back with 40% less gas.
%%
%% The EVM applied EIP-2200's divisor while applying EIP-3529's refund amounts, so
%% the cap and the refund it was capping came from different forks. That is not a
%% rounding difference: it is the difference between a frame that ends with gas
%% left and one that runs out.
-spec refund_cap(atom(), integer()) -> integer().
refund_cap(Fork, GasUsed) when is_atom(Fork), is_integer(GasUsed), GasUsed >= 0 ->
    case at_least(Fork, london) of
        true -> GasUsed div 5;
        false -> GasUsed div 2
    end;
refund_cap(_Fork, _GasUsed) ->
    0.

%% Does SELFDESTRUCT delete an account's code and storage *unconditionally* at
%% this fork?
%%
%% True before Cancun, where it always did. From EIP-6780 (Cancun) it deletes
%% them only for an account created in the same transaction, so the answer is
%% false and the caller has to supply the same-transaction test itself. The EIP
%% states both sides -- "the new functionality will be only to send all Ether in
%% the account ... except that the current behaviour is preserved when
%% SELFDESTRUCT is called in the same transaction a contract was created" -- so
%% this is read off the EIP rather than inferred.
%%
%% Named as a question rather than folded into a price because it is not one: the
%% gas cost of SELFDESTRUCT is 5000 at every fork, and only *what it destroys*
%% changes. A schedule carrying this as a number would be claiming the price
%% varies when it does not.
-spec selfdestruct_deletes(atom()) -> boolean().
selfdestruct_deletes(Fork) when is_atom(Fork) ->
    not at_least(Fork, cancun);
selfdestruct_deletes(_Fork) ->
    false.

dynamic_gas_cost(16#20, _Fork, Length, _Args) -> 6 * ((Length + 31) div 32);
dynamic_gas_cost(16#37, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(16#39, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(16#3C, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(16#3E, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
%% MCOPY (Cancun) copies words, not bytes, and the word size is 32 either way.
dynamic_gas_cost(16#5E, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(Op, _Fork, Length, _Args) when Op >= 16#A0, Op =< 16#A4 ->
    8 * Length;
%% EIP-3860 (Shanghai): both creators are charged 2 gas per 32-byte word of
%% init code, through initcode_word_cost/1 below. eth_tx:initcode_gas/3 charges
%% the same cost in a transaction's intrinsic gas, so the two agree rather than
%% the opcode double-counting.
%%
%% The condition is Shanghai's and it was not applied. Before EIP-3860 neither
%% CREATE nor CREATE2 paid anything for the init code about to run, so charging
%% it at a pre-Shanghai block overcharges every contract creation there by two
%% gas per word of init code.
%%
%% The term is factored out rather than written into each clause because
%% `eth_tx' has to charge the identical figure for a creation transaction's
%% `data', and two copies of a consensus constant is one too many.
dynamic_gas_cost(16#F0, Fork, Length, _Args) ->
    initcode_word_cost(Fork) * ((Length + 31) div 32);
%% CREATE2 additionally hashes the init code, at KECCAK256's per-word price.
%% The hashing term is not Shanghai's -- it is CREATE2's from Constantinople --
%% so it is charged at every fork and only the init-code term is gated.
dynamic_gas_cost(16#F5, Fork, Length, _Args) ->
    Words = (Length + 31) div 32,
    6 * Words + initcode_word_cost(Fork) * Words;
dynamic_gas_cost(_Op, _Fork, _Length, _Args) -> 0.

%% EIP-3860's per-word init-code charge, which is 2 from Shanghai and 0 before
%% it. Exported because eth_tx:initcode_gas/3 charges the same term for a
%% creation transaction's data, and the two must not be able to disagree.
-spec initcode_word_cost(atom()) -> non_neg_integer().
initcode_word_cost(Fork) when is_atom(Fork) ->
    case at_least(Fork, shanghai) of
        true -> 2;
        false -> 0
    end;
initcode_word_cost(_Fork) ->
    0.

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------

last_activation([]) -> none;
last_activation([{Kind, Point, _Fork} | Rest]) ->
    case last_activation(Rest) of
        none -> {Kind, Point};
        Other -> Other
    end.

beyond(time, Point, _BlockNumber, BlockTimestamp, _TotalDifficulty) ->
    BlockTimestamp > Point;
beyond(block, Point, BlockNumber, _BlockTimestamp, _TotalDifficulty) ->
    BlockNumber > Point;
beyond(ttd, _Point, _BlockNumber, _BlockTimestamp, _TotalDifficulty) ->
    %% Total difficulty advances neither a height nor a timestamp, so a chain whose last
    %% activation is the Merge transition has no "past the last fork" to detect.
    false.
