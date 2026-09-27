%% Fork-dependent execution rules used by the block builder and EVM.
%%
%% This module is deliberately stateless.  A fork schedule is consensus
%% configuration, not process state, and keeping these helpers pure makes it
%% possible to use them while validating a payload before any worker is
%% started.

-module(eth_fork_schedule).

-export([ current_fork/3,
          current_fork/4,
          fork_schedule/1,
          fork_at/3,
          configured_network/0,
          chain_id/0,
          chain_id/1,
          configured_fork/0,
          at_least/2,
          opcode_exists/2,
          base_fee/2,
          base_fee/3,
          base_fee_delta/2,
          burn_base_fee/2,
          blob_gas_per_blob/0,
          excess_blob_gas/2,
          blob_base_fee/2,
          blob_gas_price/1,
          fake_exponential/3,
          process_withdrawals/2,
          make_withdrawal/3,
          withdrawals_root/1,
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
          refund_cap/2,
          selfdestruct_deletes/1,
          initcode_word_cost/1,
          timestamp_in_frame/3,
          timestamp_frame/2,
          activated_at/2 ]).

-define(BASE_FEE_MAX_CHANGE_DENOMINATOR, 8).
-define(BASE_FEE_INITIAL, 1000000000).
-define(MIN_BASE_FEE, 7).
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

configured_network() ->
    case os:getenv("ETH_NETWORK") of
        false -> sepolia;
        "" -> sepolia;
        Value -> parse_network(Value)
    end.

parse_network(Value) ->
    case string:lowercase(string:trim(Value)) of
        "sepolia" -> sepolia;
        "mainnet" -> mainnet;
        "1" -> mainnet;
        "11155111" -> sepolia;
        Other ->
            logger:warning("unknown ETH_NETWORK ~p, falling back to sepolia", [Other]),
            sepolia
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
chain_id(sepolia) -> 11155111.

%% An explicit rules pin, used for networks that have no schedule in this
%% module. It is *not* consulted for a known network: silently overriding a
%% real activation point would be how a node ends up applying the wrong fork
%% rules, so ETH_FORK only applies where fork_schedule/1 has no data.
configured_fork() ->
    case os:getenv("ETH_FORK") of
        false -> cancun;
        "" -> cancun;
        Value -> parse_fork(Value)
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

parse_fork(Value) ->
    case string:lowercase(string:trim(Value)) of
        "frontier" -> frontier;
        "homestead" -> homestead;
        "dao" -> dao;
        "tangerine" -> tangerine;
        "spurious_dragon" -> spurious_dragon;
        "byzantium" -> byzantium;
        "constantinople" -> constantinople;
        "petersburg" -> petersburg;
        "istanbul" -> istanbul;
        "muir_glacier" -> muir_glacier;
        "berlin" -> berlin;
        "london" -> london;
        "arrow_glacier" -> arrow_glacier;
        "gray_glacier" -> gray_glacier;
        "merge" -> merge;
        "paris" -> paris;
        "shanghai" -> shanghai;
        "cancun" -> cancun;
        "deneb" -> deneb;
        "prague" -> prague;
        "osaka" -> osaka;
        "bpo1" -> bpo1;
        "bpo2" -> bpo2;
        "amsterdam" -> amsterdam;
        _ -> cancun
    end.

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
%% The target is two-thirds of the parent gas limit.  The formula intentionally
%% uses integer arithmetic in the same order as the consensus specification:
%% the absolute gas deviation is applied to the parent fee, divided by the
%% target, and then divided by eight.  A non-zero deviation always changes a
%% rising base fee by at least one wei.
base_fee(ParentGasUsed, ParentGasLimit) ->
    base_fee(ParentGasUsed, ParentGasLimit, ?BASE_FEE_INITIAL).

base_fee(_ParentGasUsed, 0, ParentBaseFee) when is_integer(ParentBaseFee) ->
    ParentBaseFee;
base_fee(ParentGasUsed, ParentGasLimit, ParentBaseFee)
  when is_integer(ParentGasUsed), is_integer(ParentGasLimit),
       is_integer(ParentBaseFee), ParentGasLimit > 0 ->
    Target = ParentGasLimit * 2 div 3,
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

%% Signed fee-independent target deviation.  This is useful for diagnostics
%% and is also the quantity used by base_fee/3 after applying the parent fee.
base_fee_delta(ParentGasUsed, ParentGasLimit)
  when is_integer(ParentGasUsed), is_integer(ParentGasLimit), ParentGasLimit > 0 ->
    Target = ParentGasLimit * 2 div 3,
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
-define(BLOB_GASPRICE_UPDATE_FRACTION, 3338477).
-define(MIN_BLOB_GASPRICE, 1).
-define(TARGET_BLOB_GAS_PER_BLOCK, 393216).

blob_gas_per_blob() -> 131072.

%% Excess blob gas carried into this block: the parent's excess plus the gas
%% its blobs consumed, less the per-block target, floored at zero.
excess_blob_gas(ParentExcessBlobGas, ParentBlobGasUsed)
  when is_integer(ParentExcessBlobGas), is_integer(ParentBlobGasUsed) ->
    max(0, ParentExcessBlobGas + ParentBlobGasUsed - ?TARGET_BLOB_GAS_PER_BLOCK);
excess_blob_gas(_ParentExcessBlobGas, _ParentBlobGasUsed) ->
    0.

blob_base_fee(ParentExcessBlobGas, ParentBlobGasUsed) ->
    blob_gas_price(excess_blob_gas(ParentExcessBlobGas, ParentBlobGasUsed)).

%% Blob gas price as a function of excess blob gas. This is the EIP-4844
%% fake_exponential with the minimum price as its base, so a block whose
%% predecessors used no more than the target charges 1 wei per blob gas.
blob_gas_price(ExcessBlobGas) when is_integer(ExcessBlobGas) ->
    fake_exponential(?MIN_BLOB_GASPRICE, max(0, ExcessBlobGas),
                     ?BLOB_GASPRICE_UPDATE_FRACTION);
blob_gas_price(_ExcessBlobGas) ->
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
base_gas_cost(16#31, Fork, Args) -> access_cost(Fork, 400, Args);  % BALANCE
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
base_gas_cost(16#3B, Fork, Args) -> access_cost(Fork, 700, Args);  % EXTCODESIZE
base_gas_cost(16#3C, Fork, Args) -> access_cost(Fork, 700, Args);  % EXTCODECOPY
%% RETURNDATASIZE is 2. It was routed through access_cost/3, so a Cancun read
%% cost 2600 -- a thousand times the real price, and enough to out-of-gas a loop
%% that loops over return data. RETURNDATACOPY is the one with a per-word cost,
%% and it is 3.
base_gas_cost(16#3D, _, _) -> 2;
base_gas_cost(16#3E, _, _) -> 3;
base_gas_cost(16#3F, Fork, Args) -> access_cost(Fork, 400, Args);  % EXTCODEHASH
base_gas_cost(16#40, _, _) -> 20;                                  % BLOCKHASH
base_gas_cost(Op, _, _) when Op >= 16#41, Op =< 16#46 -> 2;
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
base_gas_cost(16#54, Fork, Args) -> sload_cost(Fork, Args);
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
base_gas_cost(16#F1, Fork, Args) -> call_cost(Fork, Args);         % CALL
base_gas_cost(16#F2, Fork, Args) -> call_cost(Fork, Args);         % CALLCODE
base_gas_cost(16#F3, _, _) -> 0;                                   % RETURN
base_gas_cost(16#F4, Fork, Args) -> call_cost(Fork, Args);         % DELEGATECALL
base_gas_cost(16#F5, Fork, _) -> account_creation_cost(Fork);       % CREATE2
base_gas_cost(16#FA, Fork, Args) -> call_cost(Fork, Args);         % STATICCALL
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
sload_cost(Fork, Args) ->
    case at_least(Fork, berlin) of
        false -> 200;
        true ->
            case maps:get(warm, Args, false) of
                true -> 100;
                false -> 2100
            end
    end.

%% EIP-2929 (Berlin): a cold account access costs 2600 and a warm one costs
%% 100. Before Berlin the flat legacy cost applies. EIP-150 raised the
%% pre-Berlin BALANCE cost to 400, so the pre-Berlin value is passed in.
access_cost(Fork, LegacyCost, Args) ->
    case at_least(Fork, berlin) of
        false -> LegacyCost;
        true ->
            case maps:get(warm, Args, false) of
                true -> 100;
                false -> 2600
            end
    end.

%% The CALL family: cold/warm access cost plus, for a value-bearing call, the
%% 9000 gas stipend (EIP-161) and the 25000 new-account cost (EIP-161).
call_cost(Fork, Args) ->
    Access = access_cost(Fork, 700, Args),
    case at_least(Fork, berlin) of
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
    end.

account_creation_cost(_Fork) -> 32000.
selfdestruct_cost(_Fork) -> 5000.

%% ---------------------------------------------------------------------------
%% Rules the fork selects, as opposed to prices it supplies
%% ---------------------------------------------------------------------------
%% ---------------------------------------------------------------------------
%% Not every fork-dependent rule is a number in a table. Some of them are a
%% question with a boolean answer -- may this frame delete an account's storage,
%% may this transaction's refunds exceed this -- and those are here, next to the
%% prices, so that "what does this fork do" is answerable from one module.

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
