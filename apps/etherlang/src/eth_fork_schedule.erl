%% Fork-dependent execution rules used by the block builder and EVM.
%%
%% This module is deliberately stateless.  A fork schedule is consensus
%% configuration, not process state, and keeping these helpers pure makes it
%% possible to use them while validating a payload before any worker is
%% started.

-module(eth_fork_schedule).

-export([ current_fork/3,
          fork_schedule/1,
          fork_at/3,
          configured_network/0,
          chain_id/0,
          chain_id/1,
          configured_fork/0,
          at_least/2,
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
          apply_withdrawals_to_state/2,
          gas_cost/3,
          gas_cost/4 ]).

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
%% SCOPE -- the Merge is a total-difficulty activation, not a block number or
%% a timestamp. A selector given only (number, timestamp) therefore cannot
%% distinguish a pre-Merge block from a post-Merge one, and this client does
%% not attempt to: it validates PoS execution payloads only, so Paris is the
%% floor of the modelled range. Pre-Merge historical execution is out of
%% scope, and for that reason Paris is the first fork reported for any block.
%% Choosing a merge block number here would be guessing, so none is written
%% down.
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
    [{block, 0, homestead},
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
current_fork(Network, BlockNumber, BlockTimestamp)
  when is_integer(BlockNumber), is_integer(BlockTimestamp) ->
    case fork_schedule(Network) of
        [] ->
            %% No schedule for this network, so fall back to the operator's
            %% rules pin rather than guessing from the network name.
            {ok, configured_fork()};
        Schedule ->
            Active = [Fork || {Kind, Point, Fork} <- Schedule, reached(Kind, Point,
                                                                     BlockNumber,
                                                                     BlockTimestamp)],
            {ok, highest_ranked(Active)}
    end.

reached(block, Point, BlockNumber, _BlockTimestamp) -> BlockNumber >= Point;
reached(time, Point, _BlockNumber, BlockTimestamp) -> BlockTimestamp >= Point.

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
%% rank; the difficulty-bomb forks (Muir/Arrow/Gray Glacier) change no
%% execution rule and share the rank of the fork that introduced the rule they
%% delay.
fork_rank(homestead) -> 0;
fork_rank(dao) -> 0;
fork_rank(tangerine) -> 0;
fork_rank(spurious_dragon) -> 0;
fork_rank(byzantium) -> 0;
fork_rank(constantinople) -> 0;
fork_rank(petersburg) -> 0;
fork_rank(istanbul) -> 1;
fork_rank(muir_glacier) -> 1;
fork_rank(berlin) -> 2;
fork_rank(london) -> 3;
fork_rank(arrow_glacier) -> 4;
fork_rank(gray_glacier) -> 5;
fork_rank(merge) -> 6;
fork_rank(paris) -> 7;
fork_rank(shanghai) -> 8;
fork_rank(cancun) -> 9;
fork_rank(deneb) -> 9;
fork_rank(prague) -> 10;
fork_rank(osaka) -> 11;
fork_rank(bpo1) -> 12;
fork_rank(bpo2) -> 13;
fork_rank(amsterdam) -> 14;
fork_rank(_) -> 0.

at_least(Fork, Feature) ->
    fork_rank(Fork) >= fork_rank(Feature).

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
            Code = eth_state:code(State, ?BEACON_ROOTS_ADDRESS),
            case Code of
                <<>> ->
                    %% "if no code exists at BEACON_ROOTS_ADDRESS, the call must
                    %% fail silently"
                    {ok, State};
                _ ->
                    Msg = #{caller => ?SYSTEM_ADDRESS,
                            origin => ?SYSTEM_ADDRESS,
                            address => ?BEACON_ROOTS_ADDRESS,
                            value => 0,
                            data => Root,
                            gas_price => 0,
                            static => false,
                            depth => 0},
                    Env = #{timestamp => Timestamp, number => 0,
                            coinbase => <<0:160>>, prevrandao => <<0:256>>,
                            gas_limit => 0, base_fee => 0,
                            chain_id => chain_id(),
                            state => State},
                    %% The call must "execute to completion" or "fail silently",
                    %% so neither outcome is an error here -- and neither is
                    %% charged to the block's gas limit, which is why the gas
                    %% left over is discarded.
                    try eth_evm:run(Code, Msg, State, Env, ?BEACON_ROOTS_GAS) of
                        {ok, _Out, _GasLeft, St, _Logs} -> {ok, St};
                        {revert, _Out, _GasLeft, _St, _Logs} -> {ok, State};
                        {error, _Reason, _St, _Logs} -> {ok, State}
                    catch
                        _:_ -> {ok, State}
                    end
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

base_gas_cost(16#00, _, _) -> 0;
base_gas_cost(16#01, _, _) -> 3;
base_gas_cost(16#02, _, _) -> 5;
base_gas_cost(16#03, _, _) -> 3;
base_gas_cost(16#04, _, _) -> 5;
base_gas_cost(16#05, _, _) -> 5;
base_gas_cost(16#06, _, _) -> 5;
base_gas_cost(16#07, _, _) -> 5;
base_gas_cost(16#08, _, _) -> 8;
base_gas_cost(16#09, _, _) -> 8;
base_gas_cost(16#0A, _, _) -> 10;
base_gas_cost(16#0B, _, _) -> 5;
base_gas_cost(Op, _, _) when Op >= 16#10, Op =< 16#1D -> 3;
base_gas_cost(16#20, _, _) -> 30;
base_gas_cost(16#30, _, _) -> 2;
base_gas_cost(16#31, Fork, Args) -> access_cost(Fork, 400, Args);
base_gas_cost(16#32, _, _) -> 2;
base_gas_cost(16#33, _, _) -> 2;
base_gas_cost(16#34, _, _) -> 2;
base_gas_cost(Op, _, _) when Op >= 16#35, Op =< 16#3A -> 3;
base_gas_cost(16#3B, Fork, Args) -> access_cost(Fork, 700, Args);
base_gas_cost(16#3C, Fork, Args) -> access_cost(Fork, 700, Args);
base_gas_cost(16#3D, Fork, Args) -> access_cost(Fork, 700, Args);
base_gas_cost(16#3E, _, _) -> 2;
base_gas_cost(16#3F, Fork, Args) -> access_cost(Fork, 400, Args);
base_gas_cost(16#40, _, _) -> 20;
base_gas_cost(Op, _, _) when Op >= 16#41, Op =< 16#46 -> 2;
base_gas_cost(16#47, Fork, _) -> account_creation_cost(Fork);
base_gas_cost(16#48, _, _) -> 20;
base_gas_cost(16#49, _, _) -> 20;
base_gas_cost(16#4A, _, _) -> 20;
base_gas_cost(Op, _, _) when Op >= 16#50, Op =< 16#5B -> 2;
base_gas_cost(Op, _, _) when Op >= 16#60, Op =< 16#9F -> 3;
base_gas_cost(Op, _, _) when Op >= 16#A0, Op =< 16#A4 -> 375 * (Op - 16#A0 + 1);
base_gas_cost(16#F0, Fork, _) -> account_creation_cost(Fork);
base_gas_cost(16#F1, Fork, Args) -> call_cost(Fork, Args);
base_gas_cost(16#F2, Fork, Args) -> call_cost(Fork, Args);
base_gas_cost(16#F3, _, _) -> 0;
base_gas_cost(16#F4, Fork, Args) -> call_cost(Fork, Args);
base_gas_cost(16#F5, Fork, _) -> account_creation_cost(Fork);
base_gas_cost(16#FA, Fork, Args) -> call_cost(Fork, Args);
base_gas_cost(16#FF, Fork, _) -> selfdestruct_cost(Fork);
base_gas_cost(16#FE, _, _) -> 5000;
base_gas_cost(_, _, _) -> 0.

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

dynamic_gas_cost(16#20, _Fork, Length, _Args) -> 6 * ((Length + 31) div 32);
dynamic_gas_cost(16#37, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(16#39, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(16#3C, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(16#3D, _Fork, Length, _Args) -> 3 * ((Length + 31) div 32);
dynamic_gas_cost(Op, _Fork, Length, _Args) when Op >= 16#A0, Op =< 16#A4 ->
    8 * Length;
dynamic_gas_cost(_Op, _Fork, _Length, _Args) -> 0.

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------
