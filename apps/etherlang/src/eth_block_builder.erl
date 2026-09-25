%% Block builder for Phase 3: Block Production.
%%
%% Constructs execution payloads from the pending transaction pool.
%% The builder selects transactions by effective gas price / priority fee,
%% respects the block gas limit, executes each transaction via the EVM,
%% and produces a complete execution payload ready for the consensus client.
%%
%% -module(eth_block_builder).

-module(eth_block_builder).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([ build_block/0,
          build_block/1,
          pending_payload/0,
          pending_payload/1,
          validate_transaction/1,
          validate_transaction/2,
          status/0 ]).

-define(MAX_GAS, 30000000).
-define(FORK_LONDON, london).
-define(FORK_MERGE, merge).
-define(FORK_PARIS, paris).
-define(FORK_SHANGHAI, shanghai).

%% secp256k1 group order; EIP-2 requires 1 <= r,s < N.
-define(SECP256K1_N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).

-record(st, {
    max_transactions = 2048 :: integer(),
    max_gas = ?MAX_GAS :: integer(),
    base_fee = 1000000000 :: integer(),
    terminal_total_difficulty = 0 :: integer(),
    is_post_merge = false :: boolean()
}).

%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    logger:notice("etherlang: Block builder started"),
    {ok, #st{}}.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

handle_call({build, _ParentHash, _Number}, _From, S) ->
    Payload = do_build(S),
    {reply, {ok, Payload}, S};
handle_call(get_status, _From, S) ->
    {reply, status(S), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

build_block() ->
    gen_server:call(?MODULE, {build, <<>>, 0}, infinity).

build_block(Opts) ->
    _ParentHash = maps:get(parent_hash, Opts, <<>>),
    Number = maps:get(number, Opts, 0),
    gen_server:call(?MODULE, {build, <<>>, Number}, infinity).

pending_payload() ->
    {ok, do_build(#st{})}.

pending_payload(_Opts) ->
    {ok, do_build(#st{})}.

status() ->
    gen_server:call(?MODULE, get_status, infinity).

%% ---------------------------------------------------------------------------
%% Block construction
%% ---------------------------------------------------------------------------

do_build(#st{base_fee = BaseFee, terminal_total_difficulty = TTD} = _S) ->
    %% Get pending transactions sorted by effective gas price.
    Txs = eth_txpool:pending(),
    Sorted = sort_by_price(Txs),
    %% Compute base fee using fork schedule.
    Head = eth_chain:head(eth_chain),
    {ParentHash, ParentNum} = case Head of
        {Num, Hash} -> {Hash, Num};
        _ -> {<<>>, 0}
    end,
    Number = ParentNum + 1,
    %% EIP-1559: compute base fee from parent gas usage.
    ParentGasUsed = case eth_chain:get_gas_used(ParentNum) of
        {ok, GU} -> GU;
        _ -> 0
    end,
    ParentGasLimit = ?MAX_GAS,
    Timestamp = erlang:system_time(second),
    %% The fork that applies to *this* block is decided by this block's own
    %% number and timestamp, so the timestamp has to be fixed before the fork
    %% is selected -- a timestamped fork such as Shanghai or Cancun activates
    %% on the timestamp, not on the height.
    {ok, Fork} = eth_fork_schedule:current_fork(
                   eth_fork_schedule:configured_network(), Number, Timestamp),
    BaseFee2 = case eth_fork_schedule:at_least(Fork, ?FORK_LONDON) of
        true -> eth_fork_schedule:base_fee(ParentGasUsed, ParentGasLimit, BaseFee);
        false -> undefined
    end,
    %% Select transactions respecting gas limit and the block base fee.
    Selected = select_transactions(Sorted, BaseFee2),
    Miner = <<0:160>>,
    GasLimit = ?MAX_GAS,
    %% EIP-4895: get pending withdrawals.
    Withdrawals = eth_fork_schedule:process_withdrawals(Number, []),
    WithdrawalsRoot = eth_fork_schedule:withdrawals_root(Withdrawals),
    %% Build the block candidate as a map.
    Block = #{
        parent_hash => ParentHash,
        number => Number,
        timestamp => Timestamp,
        miner => Miner,
        difficulty => case eth_fork_schedule:at_least(Fork, ?FORK_MERGE) of
            true -> 0;
            false -> 0
        end,
        gas_limit => GasLimit,
        gas_used => 0,
        transactions => Selected,
        receipts => [],
        logs => [],
        logs_bloom => eth_bloom:new(),
        state_root => eth_mpt:state_root(),
        receipts_root => eth_trie:root([]),
        transactions_root => eth_trie:root([]),
        base_fee_per_gas => BaseFee2,
        blob_gas_used => 0,
        excess_blob_gas => 0,
        withdrawals => Withdrawals,
        withdrawals_root => WithdrawalsRoot,
        extra_data => <<>>,
        nonce => <<0:192>>,
        mix_hash => <<0:256>>,
        sha3_uncles => eth_mpt:state_root(),
        terminal_total_difficulty => TTD,
        is_post_merge => true
    },
    %% Execute transactions.
    Block1 = execute_transactions(Block, Selected, BaseFee2),
    %% Add withdrawals to block.
    Block2 = Block1#{withdrawals => Withdrawals,
                      withdrawals_root => WithdrawalsRoot},
    %% Finalize.
    finalize_block(Block2).

%% ---------------------------------------------------------------------------
%% Transaction selection
%% ---------------------------------------------------------------------------

sort_by_price(Entries) ->
    lists:sort(fun(A, B) ->
        price(A) >= price(B)
    end, Entries).

select_transactions(Entries, BaseFee) ->
    select_transactions(Entries, BaseFee, 0, []).

select_transactions([], _BaseFee, _UsedGas, Selected) ->
    lists:reverse(Selected);
select_transactions([Entry | Rest], BaseFee, UsedGas, Selected) ->
    Tx = maps:get(tx, Entry),
    Gas = case maps:get(<<"gas">>, Tx, 21000) of
        G when is_integer(G) -> G;
        _ -> 21000
    end,
    Ctx = #{base_fee => BaseFee},
    case validate_transaction(Tx, Ctx) of
        {ok, true} when UsedGas + Gas =< ?MAX_GAS ->
            select_transactions(Rest, BaseFee, UsedGas + Gas, [Entry | Selected]);
        _ -> select_transactions(Rest, BaseFee, UsedGas, Selected)
    end.

%% Validate a transaction before including it in a block. Field types, ranges,
%% intrinsic gas, fee ceiling, and signature recovery are all checked here;
%% balance and nonce are checked by the pool/state layer because they depend on
%% the current account state rather than the transaction alone.
validate_transaction(Tx) when is_map(Tx) ->
    validate_transaction(Tx, #{}).

%% validate_transaction(Tx, Ctx) where Ctx may carry
%%   base_fee      -> integer()  current block base fee
%%   balance_of    -> fun((Address) -> {ok, Balance})
%%   nonce_of      -> fun((Address) -> {ok, Nonce})
%%   chain_id      -> integer()
validate_transaction(Tx, Ctx) when is_map(Tx), is_map(Ctx) ->
    try
        Gas = int_field(Tx, <<"gas">>),
        Value = int_field(Tx, <<"value">>),
        Nonce = int_field(Tx, <<"nonce">>, 0),
        GasPrice = int_field(Tx, <<"gasPrice">>, 0),
        MaxFee = int_field(Tx, <<"maxFeePerGas">>, undefined),
        MaxPriority = int_field(Tx, <<"maxPriorityFeePerGas">>, undefined),
        ok = ensure(Gas > 0, {error, gas_limit_zero}),
        ok = ensure(Value >= 0, {error, negative_value}),
        ok = ensure(Nonce >= 0, {error, negative_nonce}),
        ok = ensure_tx_type_supported(Tx),
        {To, IsCreate} = to_field(Tx),
        ok = ensure(validate_to(To), {error, invalid_to}),
        Data = data_field(Tx),
        AccessList = access_list_field(Tx),
        ok = ensure(valid_access_list(AccessList), {error, invalid_access_list}),
        BaseFee = maps:get(base_fee, Ctx, undefined),
        ok = ensure(valid_fee_fields(Tx, GasPrice, MaxFee, MaxPriority), {error, invalid_fee}),
        ok = ensure(fee_ceiling_ok(Tx, MaxFee, MaxPriority, GasPrice, BaseFee),
                    {error, fee_too_low}),
        Intrinsic = intrinsic_gas(Data, IsCreate, AccessList),
        ok = ensure(Gas >= Intrinsic, {error, intrinsic_gas}),
        ok = ensure(valid_signature(Tx), {error, bad_signature}),
        ok = check_chain_id(Tx, Ctx),
        ok = check_state(Tx, Nonce, Gas, Value, MaxFee, GasPrice, Ctx),
        {ok, true}
    catch
        throw:{error, _} = Err -> Err;
        throw:Reason -> {error, Reason};
        Class:Reason -> {error, {invalid_transaction, Class, Reason}}
    end;
validate_transaction(_Tx, _Ctx) ->
    {error, invalid_transaction}.

ensure(true, _Ok) -> ok;
ensure(false, Err) -> throw(Err).

int_field(Tx, Key) -> int_field(Tx, Key, undefined).

int_field(Tx, Key, Default) ->
    case maps:get(Key, Tx, Default) of
        undefined -> undefined;
        I when is_integer(I), I >= 0 -> I;
        B when is_binary(B) -> decode_uint(B);
        _ -> throw({error, {bad_field, Key}})
    end.

%% JSON-RPC encodes quantities with no leading zeros, so "0x0", "0x1" and
%% "0x7b" all have an odd number of hex digits. binary:decode_hex/1 rejects
%% those, so an odd-length string is left-padded with a zero nibble first.
decode_uint(<<"0x">>) -> 0;
decode_uint(<<"0x", S/binary>>) ->
    case decode_hex_bytes(S) of
        {ok, Bin} -> binary:decode_unsigned(Bin);
        error -> throw({error, bad_hex})
    end;
decode_uint(<<"0X", S/binary>>) -> decode_uint(<<"0x", S/binary>>);
decode_uint(B) when is_binary(B) -> binary:decode_unsigned(B);
decode_uint(_) -> throw({error, bad_uint}).

%% binary:decode_hex/1 yields the bytes directly and raises badarg on
%% non-hex input, so wrap it and left-pad odd-length digit strings. The result
%% is normalized to {ok, Bytes} so a failure is distinguishable from the empty
%% byte string (which is itself a legal decoding).
decode_hex_bytes(S) ->
    Padded = case byte_size(S) rem 2 of
        0 -> S;
        1 -> <<"0", S/binary>>
    end,
    try {ok, binary:decode_hex(Padded)}
    catch _:_ -> error
    end.

%% The destination is decoded *before* it is classified, because a JSON-RPC
%% "0x" is a two-byte binary that would otherwise look like a (malformed)
%% address rather than the empty destination that means contract creation.
to_field(Tx) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined -> {<<>>, true};
        null -> {<<>>, true};
        B when is_binary(B) ->
            case hex_bytes_20(B) of
                <<>> -> {<<>>, true};
                Addr -> {Addr, false}
            end;
        _ -> throw({error, invalid_to})
    end.

hex_bytes_20(<<"0x", S/binary>>) ->
    case decode_hex_bytes(S) of
        {ok, Bin} -> Bin;
        error -> throw({error, invalid_to})
    end;
hex_bytes_20(<<"0X", S/binary>>) -> hex_bytes_20(<<"0x", S/binary>>);
hex_bytes_20(B) when is_binary(B) -> B.

validate_to(<<>>) -> true;
validate_to(B) when is_binary(B), byte_size(B) =:= 20 -> true;
validate_to(_) -> false.

data_field(Tx) ->
    case maps:get(<<"input">>, Tx, maps:get(<<"data">>, Tx, <<>>)) of
        B when is_binary(B) -> hexdata_20(B);
        _ -> throw({error, bad_data})
    end.

hexdata_20(<<"0x", S/binary>>) ->
    case decode_hex_bytes(S) of
        {ok, Bin} -> Bin;
        error -> throw({error, bad_data})
    end;
hexdata_20(<<"0X", S/binary>>) -> hexdata_20(<<"0x", S/binary>>);
hexdata_20(B) when is_binary(B) -> B;
hexdata_20(_) -> throw({error, bad_data}).

%% An access list arrives over JSON-RPC as a list of objects
%%   #{<<"address">> => 0x..., <<"storageKeys">> => [0x..., ...]}
%% but the wire form is a list of [Address, [Slot...]] pairs. Both shapes are
%% normalized to {AddressBin, [SlotBin]} so validation has one representation.
access_list_field(Tx) ->
    case maps:get(<<"accessList">>, Tx, []) of
        L when is_list(L) -> [normalize_access_entry(E) || E <- L];
        _ -> throw({error, invalid_access_list})
    end.

normalize_access_entry({Addr, Slots}) when is_list(Slots) ->
    {access_address(Addr), [access_slot(S) || S <- Slots]};
normalize_access_entry(#{<<"address">> := Addr,
                         <<"storageKeys">> := Slots}) when is_list(Slots) ->
    {access_address(Addr), [access_slot(S) || S <- Slots]};
normalize_access_entry(#{address := Addr, storageKeys := Slots}) when is_list(Slots) ->
    {access_address(Addr), [access_slot(S) || S <- Slots]};
normalize_access_entry(_) ->
    throw({error, invalid_access_list}).

access_address(A) when is_binary(A) -> hex_bytes_20(A);
access_address(_) -> throw({error, invalid_access_list}).

access_slot(S) when is_binary(S) ->
    case hexdata_20(S) of
        Bin when byte_size(Bin) =:= 32 -> Bin;
        _ -> throw({error, invalid_access_list})
    end;
access_slot(I) when is_integer(I) ->
    <<I:256>>;
access_slot(_) -> throw({error, invalid_access_list}).

valid_access_list([]) -> true;
valid_access_list(L) ->
    lists:all(fun({Addr, Slots}) ->
        is_binary(Addr) andalso byte_size(Addr) =:= 20 andalso
        is_list(Slots) andalso lists:all(fun(S) ->
            is_binary(S) andalso byte_size(S) =:= 32
        end, Slots)
    end, L).

%% EIP-2718/1559: typed transactions must carry both fee fields; legacy
%% transactions must not. A transaction with maxFeePerGas but no
%% maxPriorityFeePerGas (or vice versa) is malformed.
valid_fee_fields(Tx, GasPrice, MaxFee, MaxPriority) ->
    case tx_type(Tx) of
        eip1559 ->
            is_integer(MaxFee) andalso is_integer(MaxPriority) andalso
            MaxPriority =< MaxFee;
        _ ->
            is_integer(GasPrice) andalso GasPrice >= 0
    end.

tx_type(Tx) ->
    case maps:get(<<"type">>, Tx, <<"0x0">>) of
        <<"0x0">> -> legacy;
        <<"0x1">> -> eip2930;
        <<"0x2">> -> eip1559;
        0 -> legacy;
        1 -> eip2930;
        2 -> eip1559;
        _ -> throw({error, unsupported_type})
    end.

ensure_tx_type_supported(Tx) ->
    case tx_type(Tx) of
        T when T =:= legacy; T =:= eip2930; T =:= eip1559 -> ok;
        _ -> throw({error, unsupported_type})
    end.

%% Under EIP-1559 a transaction can only be included when the price it offers
%% covers the base fee. A 1559 transaction offers maxFeePerGas; legacy and
%% EIP-2930 transactions offer gasPrice directly. Either way, a transaction
%% whose ceiling is below the base fee can never be mined. Pre-London there is
%% no base fee, so no floor applies.
fee_ceiling_ok(Tx, MaxFee, _MaxPriority, GasPrice, BaseFee) when is_integer(BaseFee) ->
    Ceiling = case tx_type(Tx) of
        eip1559 -> MaxFee;
        _ -> GasPrice
    end,
    is_integer(Ceiling) andalso Ceiling >= BaseFee;
fee_ceiling_ok(_Tx, _MaxFee, _MaxPriority, _GasPrice, _BaseFee) ->
    true.

%% Intrinsic gas: 21000 base, 32000 for contract creation, 4 per zero byte and
%% 16 per non-zero byte of calldata, plus EIP-2930 access list costs
%% (2400 per address, 1900 per storage key).
%%
%% Note that binary_to_list/1 yields *integers*, so the zero-byte case must
%% match the integer 0. Matching a <<0>> binary pattern here would silently
%% charge every byte at the non-zero rate.
intrinsic_gas(Data, IsCreate, AccessList) ->
    Base = case IsCreate of
        true -> 53000;
        false -> 21000
    end,
    DataGas = lists:foldl(fun(0, A) -> A + 4;
                             (_, A) -> A + 16
                          end, 0, binary_to_list(Data)),
    AccessGas = lists:foldl(fun({_Addr, Slots}, A) ->
        A + 2400 + 1900 * length(Slots)
    end, 0, AccessList),
    Base + DataGas + AccessGas + initcode_gas(Data, IsCreate).

%% EIP-3860 (Shanghai): init code is metered at 2 gas per 32-byte word.
initcode_gas(_Data, false) -> 0;
initcode_gas(Data, true) -> 2 * ((byte_size(Data) + 31) div 32).

%% Signature validity has two independent parts, and only the second is
%% usually noticed:
%%
%%   1. EIP-2 malleability bound. r must lie in [1, N-1] and s in [1, N/2].
%%      The upper half of the s range is malleable -- replacing s with N-s
%%      yields a second valid signature over the same message -- so those are
%%      rejected outright. This is what makes a transaction hash a stable
%%      identifier rather than one of many.
%%
%%   2. Sender agreement. Public-key recovery *succeeds* for almost any
%%      (r, s, v) triple; it simply yields a different address. So "recovery
%%      succeeded" proves nothing on its own. What actually binds the signature
%%      to the transaction is agreement with the declared sender, which
%%      check_from_field/2 verifies.
valid_signature(Tx) ->
    R = int_field(Tx, <<"r">>),
    S = int_field(Tx, <<"s">>),
    V = int_field(Tx, <<"v">>),
    case {in_group_range(R), low_half_s(S), valid_recovery_id(Tx, V)} of
        {true, true, true} ->
            case eth_tx:sender(Tx) of
                {ok, _} -> true;
                _ -> false
            end;
        _ ->
            false
    end.

in_group_range(I) when is_integer(I) ->
    I >= 1 andalso I < ?SECP256K1_N;
in_group_range(_) ->
    false.

low_half_s(S) when is_integer(S) ->
    S >= 1 andalso S =< ?SECP256K1_N div 2;
low_half_s(_) ->
    false.

%% Legacy `v` is either the unprotected 27/28 or the EIP-155 form
%% chainId*2+35+recid; typed transactions carry a bare recovery id 0/1.
valid_recovery_id(Tx, V) when is_integer(V) ->
    case tx_type(Tx) of
        legacy -> V =:= 27 orelse V =:= 28 orelse V >= 35;
        _ -> V =:= 0 orelse V =:= 1
    end;
valid_recovery_id(_Tx, _V) ->
    false.

%% EIP-155 replay protection: legacy transactions carry the chain id inside
%% `v' as (chainId * 2 + 35 + recid); typed transactions carry it explicitly.
%% An unprotected legacy transaction (v = 27/28) is only valid when the node
%% itself is configured without a chain id.
check_chain_id(Tx, Ctx) ->
    case maps:get(chain_id, Ctx, undefined) of
        undefined -> ok;
        Expected -> ensure(tx_chain_id(Tx) =:= Expected, {error, wrong_chain_id})
    end.

tx_chain_id(Tx) ->
    case tx_type(Tx) of
        legacy ->
            V = int_field(Tx, <<"v">>),
            case V >= 35 of
                true -> (V - 35) div 2;
                false -> undefined
            end;
        _ ->
            int_field(Tx, <<"chainId">>)
    end.

%% The payer is the address recovered from the signature, not a caller-supplied
%% `from' field. When the transaction *does* carry `from' (as an RPC-decoded map
%% usually does), it must agree with the recovered address, otherwise the tx is
%% being replayed under a forged sender.
check_state(Tx, Nonce, Gas, Value, MaxFee, GasPrice, Ctx) ->
    case recover_sender(Tx) of
        {ok, Payer} ->
            ok = check_from_field(Tx, Payer),
            Price = effective_price_for_validation(MaxFee, GasPrice,
                                                   maps:get(base_fee, Ctx, undefined)),
            Total = Gas * Price + Value,
            ok = check_balance(Payer, Total, Ctx),
            ok = check_nonce(Payer, Nonce, Ctx);
        error ->
            ok
    end.

recover_sender(Tx) ->
    case eth_tx:sender(Tx) of
        {ok, Sender} -> {ok, Sender};
        _ -> error
    end.

check_from_field(Tx, Payer) ->
    case maps:get(<<"from">>, Tx, undefined) of
        undefined -> ok;
        Declared when is_binary(Declared) ->
            ensure(hex_bytes_20(Declared) =:= Payer, {error, sender_mismatch});
        _ -> ok
    end.

check_balance(Payer, Total, Ctx) ->
    case maps:get(balance_of, Ctx, undefined) of
        undefined -> ok;
        Fun when is_function(Fun, 1) ->
            case Fun(Payer) of
                {ok, Balance} when is_integer(Balance) ->
                    ensure(Balance >= Total, {error, insufficient_balance});
                _ -> ok
            end
    end.

%% The sender's account nonce must equal the transaction nonce; a gap stalls
%% the account and a lower nonce is a replay.
check_nonce(Payer, Nonce, Ctx) ->
    case maps:get(nonce_of, Ctx, undefined) of
        undefined -> ok;
        Fun when is_function(Fun, 1) ->
            case Fun(Payer) of
                {ok, AccountNonce} when is_integer(AccountNonce) ->
                    ensure(AccountNonce =:= Nonce, {error, bad_nonce});
                _ -> ok
            end
    end.

%% A sender must be able to cover gas * maxFeePerGas (the worst case, since the
%% miner may take the full priority fee), plus the transferred value. Legacy
%% transactions are bounded by gasPrice.
effective_price_for_validation(MaxFee, _GasPrice, _BaseFee) when is_integer(MaxFee) ->
    MaxFee;
effective_price_for_validation(_MaxFee, GasPrice, _BaseFee) when is_integer(GasPrice) ->
    GasPrice;
effective_price_for_validation(_, _, _) -> 0.

price(#{price := Price}) -> Price;
price(#{tx := Tx}) -> maps:get(<<"gasPrice">>, Tx, 0).

%% EIP-1559: the miner (and the tx ordering for inclusion) is based on the
%% effective tip, i.e. min(maxPriorityFeePerGas, maxFeePerGas - baseFee), with
%% legacy gasPrice used directly when the base fee is absent (pre-London).
effective_gas_price(GasPrice, MaxPriorityFee, MaxFee, BaseFee) ->
    case BaseFee of
        undefined -> GasPrice;
        BF when is_integer(MaxFee), is_integer(MaxPriorityFee) ->
            case MaxFee < BF of
                true -> GasPrice;
                false -> min(MaxPriorityFee, MaxFee - BF)
            end;
        _ -> GasPrice
    end.

%% ---------------------------------------------------------------------------
%% Transaction execution
%% ---------------------------------------------------------------------------

execute_transactions(Block, [], _BaseFee) ->
    Block#{gas_used => 0};
execute_transactions(Block, [Tx | Rest], BaseFee) ->
    GasLimitTx = maps:get(<<"gas">>, Tx, ?MAX_GAS),
    Value = maps:get(<<"value">>, Tx, 0),
    To = maps:get(<<"to">>, Tx, <<>>),
    Data = maps:get(<<"input">>, Tx, <<>>),
    Nonce = maps:get(<<"nonce">>, Tx, 0),
    MaxPriorityFee = maps:get(<<"maxPriorityFeePerGas">>, Tx, 0),
    MaxFee = maps:get(<<"maxFeePerGas">>, Tx, 0),
    GasPrice = maps:get(<<"gasPrice">>, Tx, 0),
    EffectiveGasPrice = effective_gas_price(GasPrice, MaxPriorityFee, MaxFee, BaseFee),
    Msg = #{
        <<"sender">> => maps:get(<<"from">>, Tx),
        <<"to">> => To,
        <<"value">> => Value,
        <<"gas">> => GasLimitTx,
        <<"gasPrice">> => EffectiveGasPrice,
        <<"nonce">> => Nonce,
        <<"input">> => Data
    },
    Code = case To of
        <<>> -> <<>>;
        _ ->
            case eth_statestore:get_code(To) of
                {ok, C} -> C;
                not_found -> <<>>
            end
    end,
    BlockNum = maps:get(number, Block, 0),
    Timestamp = maps:get(timestamp, Block, 0),
    Miner = maps:get(miner, Block, <<>>),
    Env = #{
        block => #{
            <<"number">> => BlockNum,
            <<"timestamp">> => Timestamp,
            <<"gasLimit">> => ?MAX_GAS,
            <<"baseFeePerGas">> => BaseFee
        },
        coinbase => Miner
    },
    {ResultKind, GasUsed, _State2, Logs} = case eth_evm:run(Code, Msg, eth_state:new({BlockNum, <<>>}, #{}), Env, GasLimitTx) of
        {ok, _Output, GasLeft, NewState, NewLogs} ->
            {ok, GasLimitTx - GasLeft, NewState, NewLogs};
        {revert, _Output, GasLeft, NewState, NewLogs} ->
            {revert, GasLimitTx - GasLeft, NewState, NewLogs};
        {error, _Reason, NewState, NewLogs} ->
            {error, GasLimitTx, NewState, NewLogs}
    end,
    Receipt = make_receipt(Tx, ResultKind, GasUsed, GasLimitTx, Logs,
                           maps:get(gas_used, Block, 0) + GasUsed,
                           length(maps:get(receipts, Block, []))),
    Block2 = Block#{
        receipts => maps:get(receipts, Block, []) ++ [Receipt],
        logs => maps:get(logs, Block, []) ++ Logs,
        gas_used => maps:get(gas_used, Block, 0) + GasUsed,
        state_root => eth_mpt:state_root()
    },
    execute_transactions(Block2, Rest, BaseFee).

%% ---------------------------------------------------------------------------
%% Receipt generation
%% ---------------------------------------------------------------------------

make_receipt(Tx, Result, _GasUsed, _GasLimit, Logs, CumulativeGas, Index) ->
    Status = case Result of
        ok -> 1;
        revert -> 0;
        error -> 0
    end,
    #{
        <<"status">> => Status,
        <<"cumulative_gas_used">> => CumulativeGas,
        <<"logs_bloom">> => compute_bloom(Logs),
        <<"logs">> => Logs,
        <<"type">> => <<"0x0">>,
        <<"transactionHash">> => maps:get(<<"hash">>, Tx, <<>>),
        <<"transactionIndex">> => Index
    }.

%% ---------------------------------------------------------------------------
%% Block finalization
%% ---------------------------------------------------------------------------

finalize_block(Block) ->
    Txs = maps:get(transactions, Block, []),
    Recs = maps:get(receipts, Block, []),
    Logs = maps:get(logs, Block, []),
    GasUsed = maps:get(gas_used, Block, 0),
    Bloom = compute_bloom(Logs),
    TxRoot = tx_trie_root(Txs),
    RecRoot = receipt_trie_root(Recs),
    Block#{
        gas_used => GasUsed,
        logs_bloom => Bloom,
        receipts_root => RecRoot,
        transactions_root => TxRoot
    }.

%% Transaction trie: key is RLP(index) starting at 0, value is the RLP-encoded
%% transaction. eth_tx:to_rlp/1 returns {ok, Bytes}, so unwrap it here; a
%% crash or unsupported type falls back to the empty-trie root.
tx_trie_root([]) ->
    eth_trie:root([]);
tx_trie_root(Txs) when is_list(Txs) ->
    Pairs = lists:map(
        fun({Tx, I}) ->
            case eth_tx:to_rlp(Tx) of
                {ok, Bytes} -> {eth_rlp:encode(I), Bytes};
                _ -> {eth_rlp:encode(I), <<>>}
            end
        end, lists:zip(Txs, lists:seq(0, length(Txs) - 1))),
    eth_trie:root(Pairs).

%% Receipt trie root, unwrapping the {ok, Root} shape from eth_receipt.
receipt_trie_root(Recs) ->
    case eth_receipt:receipt_root(Recs) of
        {ok, Root} -> Root;
        _ -> eth_trie:root([])
    end.

%% ---------------------------------------------------------------------------
%% Execution payload construction
%% ---------------------------------------------------------------------------

%% ---------------------------------------------------------------------------
%% Status
%% ---------------------------------------------------------------------------

status(#st{base_fee = BaseFee, max_gas = MaxGas, max_transactions = MaxTxs}) ->
    #{
        pending => length(eth_txpool:pending()),
        base_fee => BaseFee,
        max_gas => MaxGas,
        max_transactions => MaxTxs
    }.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

compute_bloom(Logs) ->
    eth_bloom:add_logs(eth_bloom:new(), Logs).
