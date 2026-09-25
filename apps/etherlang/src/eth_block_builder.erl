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
          status/0 ]).

-define(MAX_GAS, 30000000).

-record(st, {
    max_transactions = 2048 :: integer(),
    max_gas = ?MAX_GAS :: integer(),
    base_fee = 1000000000 :: integer()
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

do_build(#st{base_fee = BaseFee} = _S) ->
    %% Get pending transactions sorted by effective gas price.
    Txs = eth_txpool:pending(),
    Sorted = sort_by_price(Txs),
    %% Select transactions respecting gas limit.
    Selected = select_transactions(Sorted, BaseFee, 0, []),
    %% Get parent block info.
    Head = eth_chain:head(eth_chain),
    {ParentHash, Number} = case Head of
        {Num, Hash} -> {Hash, Num + 1};
        _ -> {<<>>, 0}
    end,
    Timestamp = erlang:system_time(second),
    Miner = <<0:160>>,
    GasLimit = ?MAX_GAS,
    %% Build the block candidate as a map.
    Block = #{
        parent_hash => ParentHash,
        number => Number,
        timestamp => Timestamp,
        miner => Miner,
        difficulty => 0,
        gas_limit => GasLimit,
        gas_used => 0,
        transactions => Selected,
        receipts => [],
        logs => [],
        logs_bloom => eth_bloom:new(),
        state_root => eth_mpt:state_root(),
        receipts_root => eth_trie:root([]),
        transactions_root => eth_trie:root([]),
        base_fee_per_gas => BaseFee,
        blob_gas_used => 0,
        excess_blob_gas => 0,
        withdrawals => [],
        withdrawals_root => eth_mpt:state_root(),
        extra_data => <<>>,
        nonce => <<0:192>>,
        mix_hash => <<0:256>>,
        sha3_uncles => eth_mpt:state_root()
    },
    %% Execute transactions.
    Block1 = execute_transactions(Block, Selected, BaseFee),
    %% Finalize.
    finalize_block(Block1).

%% ---------------------------------------------------------------------------
%% Transaction selection
%% ---------------------------------------------------------------------------

sort_by_price(Entries) ->
    lists:sort(fun(A, B) ->
        price(A) >= price(B)
    end, Entries).

select_transactions([], _BaseFee, _UsedGas, Selected) ->
    lists:reverse(Selected);
select_transactions([Entry | Rest], BaseFee, UsedGas, Selected) ->
    Tx = maps:get(tx, Entry),
    Gas = maps:get(<<"gas">>, Tx, 21000),
    case UsedGas + Gas > ?MAX_GAS of
        true -> lists:reverse(Selected);
        false -> select_transactions(Rest, BaseFee, UsedGas + Gas, [Entry | Selected])
    end.

price(#{price := Price}) -> Price;
price(#{tx := Tx}) -> maps:get(<<"gasPrice">>, Tx, 0).

effective_gas_price(GasPrice, MaxPriorityFee, MaxFee, BaseFee) ->
    case BaseFee of
        undefined -> GasPrice;
        BF when is_integer(MaxFee), is_integer(MaxPriorityFee) ->
            min(GasPrice, MaxFee) - max(MaxPriorityFee, BF);
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
    Receipt = make_receipt(Tx, ResultKind, GasUsed, GasLimitTx, Logs),
    OldBloom = maps:get(logs_bloom, Block, eth_bloom:new()),
    eth_bloom:add_logs(OldBloom, Logs),
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
%% Block finalization
%% ---------------------------------------------------------------------------

finalize_block(Block) ->
    Txs = maps:get(transactions, Block, []),
    Recs = maps:get(receipts, Block, []),
    Logs = maps:get(logs, Block, []),
    GasUsed = maps:get(gas_used, Block, 0),
    _Bloom = compute_bloom(Logs),
    _TxRoot = eth_trie:root([{I, eth_tx:to_rlp(Tx)} || {I, Tx} <- lists:zip(lists:seq(1, length(Txs)), Txs)]),
    RecRoot = eth_receipt:receipt_root(Recs),
    Block#{
        gas_used => GasUsed,
        
        receipts_root => RecRoot,
        transactions_root => _TxRoot
    }.

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
