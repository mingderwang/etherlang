%% Block data structures and header construction for Phase 3: Block Production.
%%
%% This module defines the execution payload structure and provides
%% header construction, receipt generation, bloom filter computation,
%% and state root verification for blocks produced by etherlang.
%%
%% Post-merge (PoS) block header fields:
%%   parentHash, sha3Uncles, miner, stateRoot, transactionsRoot,
%%   receiptsRoot, logsBloom, difficulty, number, gasLimit, gasUsed,
%%   timestamp, extraData, mixHash, nonce, baseFeePerGas,
%%   withdrawalsRoot, blobGasUsed, excessBlobGas
%%
%% -module(eth_block).

-module(eth_block).

-export([ new/2,
          header/1,
          hash/1,
          add_transaction/2,
          finalize/1,
          to_json/1,
          tx_root/1,
          receipts_root/1,
          logs_bloom/1,
          gas_used/1,
          base_fee/0,
          withdrawals_root/0 ]).

-record(block, {
    parent_hash :: binary(),
    number :: integer(),
    timestamp :: integer(),
    miner :: binary(),
    difficulty :: integer(),
    gas_limit :: integer(),
    gas_used :: integer(),
    transactions :: [map()],
    receipts :: [map()],
    logs :: [map()],
    logs_bloom :: binary(),
    state_root :: binary(),
    receipts_root :: binary(),
    transactions_root :: binary(),
    base_fee_per_gas :: integer() | undefined,
    blob_gas_used :: integer(),
    excess_blob_gas :: integer(),
    withdrawals :: [map()],
    withdrawals_root :: binary(),
    extra_data :: binary(),
    nonce :: binary(),
    mix_hash :: binary(),
    sha3_uncles :: binary()
}).

-define(MAX_GAS, 30000000).
-define(EMPTY_ROOT, <<16#56, 16#e8, 16#1f, 16#17, 16#1b, 16#cc, 16#55, 16#a6,
                       16#ff, 16#83, 16#45, 16#e6, 16#92, 16#c0, 16#f8, 16#6e,
                       16#5b, 16#48, 16#e0, 16#1b, 16#99, 16#6c, 16#ad, 16#c0,
                       16#01, 16#62, 16#2f, 16#b5, 16#e3, 16#63, 16#b4, 16#21>>).

%% ---------------------------------------------------------------------------
%% Block construction
%% ---------------------------------------------------------------------------

new(ParentHash, Number) ->
    #block{
        parent_hash = ParentHash,
        number = Number,
        timestamp = erlang:system_time(second),
        miner = <<0:160>>,
        difficulty = 0,
        gas_limit = ?MAX_GAS,
        gas_used = 0,
        transactions = [],
        receipts = [],
        logs = [],
        logs_bloom = eth_bloom:new(),
        state_root = ?EMPTY_ROOT,
        receipts_root = ?EMPTY_ROOT,
        transactions_root = ?EMPTY_ROOT,
        blob_gas_used = 0,
        excess_blob_gas = 0,
        withdrawals = [],
        withdrawals_root = ?EMPTY_ROOT,
        extra_data = <<>>,
        nonce = <<0:192>>,
        mix_hash = <<0:256>>,
        sha3_uncles = ?EMPTY_ROOT
    }.

add_transaction(Block, Tx) ->
    Block#block{transactions = Block#block.transactions ++ [Tx]}.

finalize(#block{transactions = Txs,
                gas_limit = GasLimit,
                base_fee_per_gas = BaseFee} = Block) ->
    Chain = eth_chain,
    Head = eth_chain:head(Chain),
    State = eth_state:new(Head, #{}),
    Block1 = execute_transactions(Block, Txs, State, BaseFee, GasLimit),
    StateRoot = eth_mpt:state_root(),
    %% Verify state root matches computed root.
    ok = verify_state_root(StateRoot, Block1),
    Block1#block{
        state_root = StateRoot,
        gas_used = sum_gas_used(Block1#block.receipts),
        logs_bloom = compute_bloom(Block1#block.logs),
        receipts_root = eth_receipt:receipt_root(Block1#block.receipts),
        transactions_root = tx_root(Block1#block.transactions)
    }.

%% ---------------------------------------------------------------------------
%% Transaction execution
%% ---------------------------------------------------------------------------

execute_transactions(Block, [], _State, _BF, _GL) ->
    Block;
execute_transactions(#block{number = Number, timestamp = Ts,
                     miner = Miner, base_fee_per_gas = BaseFee,
                     gas_limit = GL} = Block,
                 [Tx | Rest], State, BF, GL) ->
    GasLimitTx = maps:get(<<"gas">>, Tx, GL),
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
    Env = #{
        block => #{
            <<"number">> => Number,
            <<"timestamp">> => Ts,
            <<"gasLimit">> => GL,
            <<"baseFeePerGas">> => BaseFee
        },
        coinbase => Miner
    },
    Receipt = case eth_evm:run(Code, Msg, State, Env, GasLimitTx) of
        {ok, _Output, GasLeft, _State2, Logs} ->
            make_receipt(Tx, ok, GasLeft, GasLimitTx, Logs),
            Block#block{receipts = Block#block.receipts ++ [make_receipt(Tx, ok, GasLeft, GasLimitTx, Logs)],
                         logs = Block#block.logs ++ Logs,
                         gas_used = Block#block.gas_used + (GasLimitTx - GasLeft)};
        {revert, _Output, GasLeft, _State2, Logs} ->
            make_receipt(Tx, revert, GasLeft, GasLimitTx, Logs),
            Block#block{receipts = Block#block.receipts ++ [make_receipt(Tx, revert, GasLeft, GasLimitTx, Logs)],
                         logs = Block#block.logs ++ Logs,
                         gas_used = Block#block.gas_used + (GasLimitTx - GasLeft)};
        {error, _Reason, _State2, Logs} ->
            make_receipt(Tx, error, GasLimitTx, GasLimitTx, Logs),
            Block#block{receipts = Block#block.receipts ++ [make_receipt(Tx, error, GasLimitTx, GasLimitTx, Logs)],
                         logs = Block#block.logs ++ Logs,
                         gas_used = Block#block.gas_used + GasLimitTx}
    end,
    execute_transactions(Receipt, Rest, State, BF, GL).

make_receipt(Tx, Result, GasUsed, _GasLimit, Logs) ->
    Status = case Result of
        ok -> 1;
        revert -> 0;
        error -> 0
    end,
    #{
        <<"status">> => Status,
        <<"cumulative_gas_used">> => GasUsed,
        <<"logs_bloom">> => eth_bloom:new(),
        <<"logs">> => Logs,
        <<"type">> => <<"0x0">>,
        <<"transactionHash">> => maps:get(<<"hash">>, Tx, <<>>),
        <<"transactionIndex">> => 0
    }.

%% ---------------------------------------------------------------------------
%% Header construction
%% ---------------------------------------------------------------------------

header(#block{parent_hash = ParentHash, number = Number,
               timestamp = Ts, miner = Miner, difficulty = Diff,
               gas_limit = GasLimit, gas_used = GasUsed,
               logs_bloom = Bloom, state_root = StateRoot,
               transactions_root = TxRoot, receipts_root = RecRoot,
               extra_data = Extra, nonce = Nonce, mix_hash = Mix,
               sha3_uncles = SU, base_fee_per_gas = BaseFee,
               blob_gas_used = BG, excess_blob_gas = EG,
               withdrawals_root = WdRoot} = _Block) ->
    #{
        <<"parentHash">> => ParentHash,
        <<"sha3Uncles">> => SU,
        <<"miner">> => Miner,
        <<"stateRoot">> => StateRoot,
        <<"transactionsRoot">> => TxRoot,
        <<"receiptsRoot">> => RecRoot,
        <<"logsBloom">> => Bloom,
        <<"difficulty">> => Diff,
        <<"number">> => Number,
        <<"gasLimit">> => GasLimit,
        <<"gasUsed">> => GasUsed,
        <<"timestamp">> => Ts,
        <<"extraData">> => Extra,
        <<"mixHash">> => Mix,
        <<"nonce">> => Nonce,
        <<"baseFeePerGas">> => case BaseFee of
            undefined -> <<"0x0">>;
            BF -> eth_hex:encode_int(BF)
        end,
        <<"withdrawalsRoot">> => WdRoot,
        <<"blobGasUsed">> => BG,
        <<"excessBlobGas">> => EG
    }.

%% ---------------------------------------------------------------------------
%% Hashing and serialization
%% ---------------------------------------------------------------------------

hash(Block) ->
    eth_keccak:hash(to_rlp(Block)).

to_rlp(#block{parent_hash = PH, number = N, timestamp = Ts,
               miner = Miner, difficulty = Diff, gas_limit = GL,
               gas_used = GU, logs_bloom = Bloom, state_root = SR,
               transactions_root = TR, receipts_root = RR,
               extra_data = Extra, nonce = Nonce, mix_hash = Mix,
               sha3_uncles = SU, base_fee_per_gas = BaseFee,
               blob_gas_used = BG, excess_blob_gas = EG,
               withdrawals_root = WR} = _Block) ->
    BaseFeeInt = case BaseFee of
        undefined -> 0;
        BF -> BF
    end,
    eth_rlp:encode([PH, SU, Miner, SR, TR, RR, Bloom, Diff, N, GL, GU,
                    Ts, Extra, Mix, Nonce, BaseFeeInt, WR, BG, EG]).

%% ---------------------------------------------------------------------------
%% Roots
%% ---------------------------------------------------------------------------

tx_root(Txs) ->
    eth_trie:root([{I, eth_tx:to_rlp(Tx)} || {I, Tx} <- lists:zip(lists:seq(1, length(Txs)), Txs)]).

receipts_root(Receipts) ->
    eth_receipt:receipt_root(Receipts).

logs_bloom(Logs) ->
    eth_bloom:add_logs(eth_bloom:new(), Logs).

compute_bloom(Logs) ->
    logs_bloom(Logs).

%% ---------------------------------------------------------------------------
%% State root verification
%% ---------------------------------------------------------------------------

verify_state_root(StateRoot, _Block) ->
    ComputedRoot = eth_mpt:state_root(),
    case StateRoot =:= ComputedRoot of
        true -> ok;
        false -> {error, state_root_mismatch}
    end.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

gas_used(Block) ->
    Block#block.gas_used.

sum_gas_used(Receipts) ->
    lists:sum([maps:get(<<"cumulative_gas_used">>, R, 0) || R <- Receipts]).

effective_gas_price(GasPrice, MaxPriorityFee, MaxFee, BaseFee) ->
    case BaseFee of
        undefined -> GasPrice;
        BF when is_integer(MaxFee), is_integer(MaxPriorityFee) ->
            min(GasPrice, MaxFee) - max(MaxPriorityFee, BF);
        _ -> GasPrice
    end.

base_fee() ->
    1000000000.

withdrawals_root() ->
    ?EMPTY_ROOT.

%% ---------------------------------------------------------------------------
%% JSON serialization
%% ---------------------------------------------------------------------------

to_json(Block) ->
    header(Block).
