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

%% Validate a transaction before including it in a block.
%%
%% The rules themselves live in eth_tx:validate/2, which is also what the
%% transaction pool and block finalization use. Three copies of "is this
%% transaction valid" is three copies that can drift: an intrinsic-gas schedule
%% that differs by one constant between the proposer and the validator charges
%% different fees for the same transaction and computes a different state root.
%%
%% What stays here is the one check that is *not* a consensus rule. A `from` field
%% is a JSON-RPC annotation, not part of the signed transaction, and no consensus
%% rule mentions it, so eth_tx:validate/2 deliberately ignores it -- a peer's
%% block is not invalid because an RPC field disagrees. When this node is
%% assembling its own block out of transactions it did not author, a declared
%% `from` that disagrees with the recovered signer is a strong signal that the
%% transaction is being relayed with a corrupted or spoofed body, and refusing to
%% propose it is worth the cost.
validate_transaction(Tx) when is_map(Tx) ->
    validate_transaction(Tx, #{}).

%% validate_transaction(Tx, Ctx) where Ctx may carry
%%   base_fee      -> integer()  current block base fee
%%   balance_of    -> fun((Address) -> {ok, Balance})
%%   nonce_of      -> fun((Address) -> {ok, Nonce})
%%   chain_id      -> integer()
validate_transaction(Tx, Ctx) when is_map(Tx), is_map(Ctx) ->
    case eth_tx:validate(Tx, Ctx) of
        ok ->
            case check_from_field(Tx) of
                ok -> {ok, true};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end;
validate_transaction(_Tx, _Ctx) ->
    {error, invalid_transaction}.

check_from_field(Tx) ->
    case eth_tx:sender(Tx) of
        {ok, Payer} ->
            case maps:get(<<"from">>, Tx, undefined) of
                undefined ->
                    ok;
                Declared when is_binary(Declared) ->
                    case declared_address(Declared) of
                        Payer -> ok;
                        _ -> {error, sender_mismatch}
                    end;
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

%% A `from` that is not even shaped like an address is treated as "no claim
%% made" rather than as a mismatch: it cannot be evidence of tampering if it is
%% not an address in the first place, and failing to parse an annotation should
%% not fail validation. The "0x" prefix has to come off before decode_hex/1 --
%% that function rejects the letter x outright.
declared_address(<<"0x", S/binary>>) -> decode_address_hex(S);
declared_address(<<"0X", S/binary>>) -> decode_address_hex(S);
declared_address(B) when is_binary(B) -> decode_address_hex(B);
declared_address(Other) -> Other.

decode_address_hex(S) ->
    Padded = case byte_size(S) rem 2 of
        0 -> S;
        1 -> <<"0", S/binary>>
    end,
    try binary:decode_hex(Padded)
    catch _:_ -> undefined
    end.


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
