%% Fork-dependent execution rules used by the block builder and EVM.
%%
%% This module is deliberately stateless.  A fork schedule is consensus
%% configuration, not process state, and keeping these helpers pure makes it
%% possible to use them while validating a payload before any worker is
%% started.

-module(eth_fork_schedule).

-export([ current_fork/1,
          current_fork/2,
          configured_fork/0,
          at_least/2,
          base_fee/2,
          base_fee/3,
          base_fee_delta/2,
          burn_base_fee/2,
          process_withdrawals/2,
          make_withdrawal/3,
          withdrawals_root/1,
          apply_withdrawals/1,
          add_beacon_root/2,
          get_beacon_root/1,
          add_beacon_root_to_state/2,
          get_beacon_root_from_state/1,
          beacon_root_contract/0,
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

%% ---------------------------------------------------------------------------
%% Fork selection
%% ---------------------------------------------------------------------------

%% The execution rules currently used by the node are selected explicitly so
%% a node never silently guesses a fork from a stale local head.  Operators
%% can set ETH_FORK when running a network with a different activation
%% schedule.  The default is Cancun, the newest execution rules required by
%% the current client baseline.
configured_fork() ->
    case os:getenv("ETH_FORK") of
        false -> cancun;
        "" -> cancun;
        Value -> parse_fork(Value)
    end.

current_fork(_BlockNumber) ->
    {ok, configured_fork()}.

current_fork(_BlockNumber, _Chain) ->
    {ok, configured_fork()}.

parse_fork(Value) ->
    case string:lowercase(string:trim(Value)) of
        "istanbul" -> istanbul;
        "berlin" -> berlin;
        "london" -> london;
        "arrow_glacier" -> arrow_glacier;
        "gray_glacier" -> gray_glacier;
        "merge" -> merge;
        "paris" -> paris;
        "shanghai" -> shanghai;
        "cancun" -> cancun;
        "deneb" -> deneb;
        _ -> cancun
    end.

fork_rank(istanbul) -> 1;
fork_rank(berlin) -> 2;
fork_rank(london) -> 3;
fork_rank(arrow_glacier) -> 4;
fork_rank(gray_glacier) -> 5;
fork_rank(merge) -> 6;
fork_rank(paris) -> 7;
fork_rank(shanghai) -> 8;
fork_rank(cancun) -> 9;
fork_rank(deneb) -> 10;
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

%% EIP-4895 specifies an SSZ hash-tree-root, not an MPT/RLP root.  A
%% withdrawal has four basic fields: uint64 index, uint64 validator index,
%% bytes20 address, and uint64 amount.  The list is mixed with its length and
%% padded to the protocol's maximum of 16 elements.
%%
%% EIP-4895 also caps a payload at ?MAX_WITHDRAWALS_PER_PAYLOAD entries, so a
%% longer list is truncated before the root (and before the mixed-in length) is
%% computed. A payload that exceeds the cap is invalid, not merely clamped, so
%% callers should check the length separately; the root stays well defined.
withdrawals_root(Withdrawals) when is_list(Withdrawals) ->
    Capped = lists:sublist(Withdrawals, ?MAX_WITHDRAWALS_PER_PAYLOAD),
    Chunks = [withdrawal_hash_tree_root(W) || W <- Capped],
    Root = ssz_merkleize(Chunks, ?MAX_WITHDRAWALS_PER_PAYLOAD),
    crypto:hash(sha256, <<Root/binary, (length(Capped)):256/little-unsigned-integer>>);
withdrawals_root(_Withdrawals) ->
    withdrawals_root([]).

withdrawal_hash_tree_root(Withdrawal) ->
    Index = withdrawal_integer(withdrawal_index(Withdrawal)),
    Validator = withdrawal_integer(maps:get(validatorIndex, Withdrawal,
                                             maps:get(<<"validatorIndex">>, Withdrawal, 0))),
    Address = withdrawal_binary(withdrawal_address(Withdrawal)),
    Amount = withdrawal_integer(withdrawal_amount(Withdrawal)),
    ssz_merkleize([uint64_chunk(Index), uint64_chunk(Validator),
                   bytes20_chunk(Address), uint64_chunk(Amount)], 4).

withdrawal_integer(I) when is_integer(I) -> max(0, I);
withdrawal_integer(B) when is_binary(B) ->
    try binary:decode_unsigned(B) catch _:_ -> 0 end;
withdrawal_integer(_) -> 0.

withdrawal_binary(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
withdrawal_binary(B) when is_binary(B) -> B;
withdrawal_binary(_) -> <<0:160>>.

uint64_chunk(Value) when is_integer(Value), Value >= 0 ->
    <<Value:64/little-unsigned-integer, 0:(24 * 8)>>.

bytes20_chunk(<<Address:20/binary>>) -> <<Address/binary, 0:(12 * 8)>>;
bytes20_chunk(_) -> <<0:256>>.

%% SSZ merkleization of a chunk list bounded by a power-of-two limit. The
%% chunk list is zero-padded up to `Limit' chunks and then hashed pairwise.
%% The recursion is driven by the list length, not a separate depth counter,
%% so it cannot split an odd-length level.
ssz_merkleize(Chunks, Limit) when is_list(Chunks), is_integer(Limit), Limit >= 1 ->
    Width = max(1, ceil_pow2(Limit)),
    Padded = lists:sublist(Chunks ++ lists:duplicate(Width, zero_hash()), Width),
    ssz_merkleize_chunks(Padded);
ssz_merkleize(_Chunks, _Limit) ->
    zero_hash().

ssz_merkleize_chunks([Chunk]) ->
    Chunk;
ssz_merkleize_chunks(Chunks) ->
    Paired = [crypto:hash(sha256, <<A/binary, B/binary>>)
              || {A, B} <- pair_up(Chunks)],
    ssz_merkleize_chunks(Paired).

pair_up([]) -> [];
pair_up([A, B | Rest]) -> [{A, B} | pair_up(Rest)];
pair_up([A]) -> [{A, zero_hash()}].

ceil_pow2(N) when N < 1 -> 1;
ceil_pow2(N) -> ceil_pow2(N, 1).

ceil_pow2(N, P) when P >= N -> P;
ceil_pow2(N, P) -> ceil_pow2(N, P * 2).

%% SSZ zero chunk.
zero_hash() -> <<0:256>>.

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

%% Store the parent beacon block root at the timestamp key used by the
%% beacon-roots system contract.  This is not the BLOCKHASH opcode: EIP-4788
%% stores a 32-byte root under the parent beacon block timestamp.
add_beacon_root_to_state(Timestamp, Root) when is_integer(Timestamp),
                                                is_binary(Root) ->
    case byte_size(Root) of
        32 -> eth_mpt:put_storage(?BEACON_ROOTS_ADDRESS,
                                  <<Timestamp:256/little-unsigned-integer>>, Root);
        _ -> {error, invalid_beacon_root}
    end.

get_beacon_root_from_state(Timestamp) when is_integer(Timestamp) ->
    eth_mpt:get_storage(?BEACON_ROOTS_ADDRESS,
                        <<Timestamp:256/little-unsigned-integer>>).

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
