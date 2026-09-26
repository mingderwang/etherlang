-module(eth_call).

%% Local `eth_call`: executes a message call against the upstream state with a
%% pure-Erlang EVM (`eth_evm`) and a lazy fetched/cached state overlay
%% (`eth_state`). The EVM is opportunistic: on unsupported opcodes, crashes or
%% an unverifiable out-of-gas, the caller should proxy to the upstream node.
%%
%% call(Params) -> {ok, <<"0x..">>} | {error, {rpc_error, Map}} |
%%                 {error, {bad_params, Why}} | {error, fallback}
%%   Params: [TxMap] | [TxMap, BlockTag] | [TxMap, BlockTag, StateOverrides]

-export([call/1]).

-define(BLOCKHASH_CACHE, eth_call_blockhash_cache).
-define(BLOCKHASH_TTL_MS, 60000).
-define(DEFAULT_GAS, 30000000).

call(Params) when is_list(Params) ->
    case Params of
        [Tx | Rest] when is_map(Tx) ->
            BlockParam = case Rest of
                             [B | _] when is_binary(B) -> B;
                             [B | _] when is_integer(B) -> B;
                             _ -> latest
                         end,
            Overrides = case Rest of
                            [_, O | _] -> eth_state:overrides_from_json(O);
                            [O | _] when is_map(O) -> eth_state:overrides_from_json(O);
                            _ -> #{}
                        end,
            do_call(Tx, BlockParam, Overrides);
        _ ->
            {error, {bad_params, params_must_start_with_tx_object}}
    end;
call(_) ->
    {error, {bad_params, params_must_be_list}}.

%% ---------------------------------------------------------------------------

do_call(Tx, BlockParam, Overrides) ->
    case fetch_block(BlockParam) of
        {error, reason} ->
            {error, fallback};
        {ok, Block} ->
            case env_from_block(Block, BlockParam) of
                {error, reason} ->
                    {error, fallback};
                {ok, Env} ->
                    Gas = case maps:get(<<"gas">>, Tx, undefined) of
                              G when is_integer(G) -> eth_hex:decode(G);
                              _ -> ?DEFAULT_GAS
                          end,
                    case top_precompile(Tx) of
                        {precompile, AddrInt, Data} -> run_precompile(AddrInt, Data);
                        not_precompile ->
                            Msg = msg_from_tx(Tx, maps:get(<<"number">>, Block)),
                            State = eth_state:new(maps:get(<<"number">>, Block), Overrides),
                            Code = msg_code(Tx, State),
                            case eth_evm:run(Code, Msg, State, Env, Gas) of
                                {ok, Out, _GasLeft, _St, _Logs} ->
                                    {ok, hex(Out)};
                                {revert, Out, _GasLeft, _St, _Logs} ->
                                    {error, {rpc_error,
                                             #{<<"code">> => -32000,
                                               <<"message">> => <<"execution reverted">>,
                                               <<"data">> => hex(Out)}}};
                                {error, _Reason, _St, _Logs} ->
                                    {error, fallback}
                            end
                    end
            end
    end.

run_precompile(AddrInt, Data) ->
    case eth_evm_precompiles:precompile(AddrInt, Data) of
        {ok, Out, _Cost} -> {ok, hex(Out)};
        unsupported -> {error, fallback};
        %% The precompile ran and rejected the input. That is this node's
        %% answer, not a gap in it, so it must not become a fallback: proxying
        %% would replace a local failure with whatever another node says about
        %% the same call.
        {error, Reason} -> {error, {precompile_failed, Reason}}
    end.

%% eth_call straight to a precompile address (0x01..0x09) executes the
%% precompile directly; returns not_precompile otherwise.
top_precompile(Tx) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined ->
            not_precompile;
        ToHex when is_binary(ToHex) ->
            W = eth_word:from_bytes(eth_state:address(ToHex)),
            case eth_evm_precompiles:is_precompile(W) of
                true -> {precompile, W, tx_data(Tx)};
                false -> not_precompile
            end
    end.

%% A tx with no `to` is a contract *creation*: run the init code in `input`.
%% Otherwise run the deployed code of the destination account.
msg_code(Tx, State) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined -> tx_data(Tx);
        To -> eth_state:code(State, eth_state:address(To))
    end.

%% TransactionCall carries calldata under `input` (newer) or `data` (legacy);
%% clients use either interchangeably, so accept both.
tx_data(Tx) ->
    case maps:get(<<"input">>, Tx, undefined) of
        undefined -> hex_to_bin(maps:get(<<"data">>, Tx, <<"0x">>));
        Input -> hex_to_bin(Input)
    end.

msg_from_tx(Tx, BlockNumber) ->
    From = case maps:get(<<"from">>, Tx, undefined) of
               undefined -> <<0:160>>;
               F -> eth_state:address(F)
           end,
    To = case maps:get(<<"to">>, Tx, undefined) of
             undefined -> <<0:160>>;
             T -> eth_state:address(T)
         end,
    #{address => To,
      caller => From,
      origin => From,
      value => uint(maps:get(<<"value">>, Tx, 0)),
      data => tx_data(Tx),
      gas_price => uint(maps:get(<<"gasPrice">>, Tx, 0)),
      static => false,
      depth => 0,
      blockNumber => BlockNumber}.

env_from_block(Block, BlockParam) ->
    try
        Number = uint(maps:get(<<"number">>, Block)),
        Env = #{number => Number,
                timestamp => uint(maps:get(<<"timestamp">>, Block, 0)),
                coinbase => eth_state:address(maps:get(<<"miner">>, Block, <<0:160>>)),
                gas_limit => uint(maps:get(<<"gasLimit">>, Block, ?DEFAULT_GAS)),
                prevrandao => bin32(maps:get(<<"mixHash">>, Block, <<0:256>>)),
                base_fee => uint(maps:get(<<"baseFeePerGas">>, Block, 0)),
                blob_base_fee => uint(maps:get(<<"blobBaseFee">>, Block, 0)),
                %% The id of the network being simulated, from configuration.
                %% eth_state:chain_id/0 asks whichever upstream endpoint is
                %% configured, so a contract branching on CHAINID would be
                %% answered against a different chain than the one the rest of
                %% this env describes.
                chain_id => eth_fork_schedule:chain_id(),
                blockhash => blockhash_fun()},
        _ = BlockParam,
        {ok, Env}
    catch _:_ ->
        {error, reason}
    end.

fetch_block(Param) ->
    case eth_rpc_client:call(<<"eth_getBlockByNumber">>, [param_hex(Param), false]) of
        {ok, Block} when is_map(Block) -> {ok, Block};
        _ -> {error, reason}
    end.

param_hex(N) when is_integer(N) -> eth_hex:encode_int(N);
param_hex(Tag) when is_binary(Tag) -> Tag.
hex_to_bin(BinHex) -> try eth_state:hex_to_bin(BinHex) catch _:_ -> <<>> end.
bin32(nil) -> <<0:256>>;
bin32(Hex) when is_binary(Hex) ->
    case byte_size(eth_state:hex_to_bin(Hex)) of
        32 -> eth_state:hex_to_bin(Hex);
        _ -> <<0:256>>
    end.

uint(Hex) -> eth_hex:decode(Hex).

hex(Bin) ->
    <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

%% BLOCKHASH lookup with a short-lived TTL cache.
blockhash_fun() ->
    fun(N) ->
        case block_hash(N) of
            {ok, Bin} when byte_size(Bin) =:= 32 -> Bin;
            _ -> undefined
        end
    end.

block_hash(N) ->
    ensure_blockhash_cache(),
    Key = {blockhash, N},
    Now = now_ms(),
    try block_hash_lookup(Key, Now) of
        {ok, _} = Ok -> Ok;
        _ -> block_hash_fetch(Key, N)
    catch error:badarg ->
        %% Cache table vanished mid-request (same owner race as
        %% eth_state_cache): serve uncached rather than dying.
        block_hash_fetch(Key, N)
    end.

block_hash_lookup(Key, Now) ->
    case ets:lookup(?BLOCKHASH_CACHE, Key) of
        [{_, {ok, Bin}, Exp}] when Exp =:= infinity; Exp > Now ->
            {ok, Bin};
        _ ->
            miss
    end.

block_hash_fetch(Key, N) ->
    R = case eth_rpc_client:call(<<"eth_getBlockByNumber">>,
                                 [eth_hex:encode_int(N), false]) of
            {ok, Block} when is_map(Block) ->
                case maps:get(<<"hash">>, Block, undefined) of
                    undefined -> error;
                    H when is_binary(H) -> {ok, eth_state:hex_to_bin(H)};
                    _ -> error
                end;
            _ ->
                error
        end,
    _ = try ets:insert(?BLOCKHASH_CACHE, {Key, R, now_ms() + ?BLOCKHASH_TTL_MS})
        catch error:badarg -> ok end,
    R.

ensure_blockhash_cache() ->
    case ets:info(?BLOCKHASH_CACHE) of
        undefined ->
            _ = try ets:new(?BLOCKHASH_CACHE, [named_table, public, set,
                                               {read_concurrency, true}])
                catch error:badarg -> ok end,
            ok;
        _ ->
            ok
    end.

now_ms() -> erlang:monotonic_time(millisecond).