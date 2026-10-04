-module(eth_call).

%% Local `eth_call`: executes a message call against the upstream state with a
%% pure-Erlang EVM (`eth_evm`) and a lazy fetched/cached state overlay
%% (`eth_state`). The EVM is opportunistic: on unsupported opcodes, crashes or
%% an unverifiable out-of-gas, the caller should proxy to the upstream node.
%%
%% call(Params) -> {ok, <<"0x..">>} | {error, {rpc_error, Map}} |
%%                 {error, {bad_params, Why}} | {error, fallback}
%%   Params: [TxMap] | [TxMap, BlockTag] | [TxMap, BlockTag, StateOverrides]

-export([call/1, estimate_gas/1, least_gas/3, attempt_gas/4, classify/1]).

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
    case attempt(Tx, BlockParam, Overrides) of
        {ok, Out} ->
            {ok, hex(Out)};
        {revert, Out} ->
            {error, {rpc_error,
                     #{<<"code">> => -32000,
                       <<"message">> => <<"execution reverted">>,
                       <<"data">> => hex(Out)}}};
        {error, _Reason} ->
            {error, fallback};
        {precompile, AddrInt, Data, Fork} ->
            run_precompile(AddrInt, Data, Fork);
        {no_block, _reason} ->
            {error, fallback};
        {no_env, _reason} ->
            {error, fallback}
    end.

%% The raw outcome of one execution attempt, with the EVM's own reason kept.
%%
%% `eth_call' collapsed every EVM error into `{error, fallback}', which is right for
%% its purpose -- a local failure becomes an upstream fallback rather than a local
%% error -- and useless for estimation, where the difference between "ran out of
%% gas" and "was rejected" is the entire question. Estimation is built on this, so
%% an estimate and a call run the same code against the same state rather than two
%% near-copies of one execution path.
attempt(Tx, BlockParam, Overrides) ->
    case fetch_block(BlockParam) of
        {error, reason} ->
            {no_block, reason};
        {ok, Block} ->
            case env_from_block(Block, BlockParam) of
                {error, reason} ->
                    {no_env, reason};
                {ok, Env} ->
                    Gas = case maps:get(<<"gas">>, Tx, undefined) of
                              G when is_integer(G) -> eth_hex:decode(G);
                              _ -> ?DEFAULT_GAS
                          end,
                    case top_precompile(Tx, maps:get(fork, Env)) of
                        {precompile, AddrInt, Data, F} -> {precompile, AddrInt, Data, F};
                        not_precompile ->
                            Msg = msg_from_tx(Tx, maps:get(<<"number">>, Block)),
                            State = eth_state:new(maps:get(<<"number">>, Block),
                                                  Overrides),
                            Code = msg_code(Tx, State),
                            case eth_evm:run(Code, Msg, State, Env, Gas) of
                                {ok, Out, _GasLeft, _St, _Logs} -> {ok, Out};
                                {revert, Out, _GasLeft, _St, _Logs} -> {revert, Out};
                                {error, Reason, _St, _Logs} -> {error, Reason}
                            end
                    end
            end
    end.

%% ---------------------------------------------------------------------------
%% eth_estimateGas
%% ---------------------------------------------------------------------------
%%
%% `params' is [call, blockTagOrNumber] or [call, blockTagOrNumber, options],
%% and `options.gas', when present, replaces the search: the call is run once at
%% that gas and either succeeds or fails. Without it the method binary-searches
%% for the least gas under which the call does not run out of gas.
%%
%% Two decisions here are the ones that make the answer mean anything, and both
%% are visible in the search:
%%
%%   1. A *revert* counts as success. geth's estimator searches for the gas at
%%      which the call stops failing with "out of gas", and a revert is not that:
%%      the gas a reverting call burns is real and a client asking what it will
%%      cost is owed the answer. The first version of this treated a revert as a
%%      failure, so every call that reverts was reported as "always fails" -- an
%%      error where a number was the right answer.
%%
%%   2. Any *other* EVM error -- an invalid opcode, a write under static call, an
%%      insufficient balance -- stops the search and is reported, rather than
%%      being treated as "needs more gas". Those transactions fail at any gas
%%      limit, and searching upward would walk the whole range and then report a
%%      gas figure for a call that can never succeed. A gas estimate for a
%%      transaction that cannot run is a number nobody can use.
-spec estimate_gas(list()) -> {ok, non_neg_integer()} | {error, term()}.
estimate_gas(Params) when is_list(Params) ->
    case Params of
        [Tx | Rest] when is_map(Tx) ->
            BlockParam = case Rest of
                             [B | _] when is_binary(B) -> B;
                             [B | _] when is_integer(B) -> B;
                             _ -> latest
                         end,
            Overrides = case Rest of
                            [_, O | _] when is_map(O) -> eth_state:overrides_from_json(O);
                            [O | _] when is_map(O) -> eth_state:overrides_from_json(O);
                            _ -> #{}
                        end,
            estimate(Tx, BlockParam, Overrides);
        _ ->
            {error, {bad_params, params_must_start_with_tx_object}}
    end;
estimate_gas(_) ->
    {error, {bad_params, params_must_be_list}}.

estimate(Tx, BlockParam, Overrides) ->
    case gas_option(Tx) of
        {explicit, Gas} when is_integer(Gas), Gas > 0 ->
            %% A caller-supplied ceiling replaces the search: run once and report
            %% whether that ceiling was enough. Geth answers an error naming the
            %% supplied figure, and saying so is more useful than a number the
            %% caller did not ask for.
            case attempt_gas(Tx, BlockParam, Overrides, Gas) of
                ok -> {ok, Gas};
                {error, Reason} -> {error, {insufficient_gas, Gas, Reason}}
            end;
        _ ->
            {Ceil, Fork} = case block_gas_limit_and_fork(BlockParam) of
                               {ok, L, F} -> {L, F};
                               undefined -> {undefined, eth_fork_schedule:configured_fork()}
                           end,
            Floor = intrinsic_floor(Tx, Fork),
            case Ceil of
                undefined ->
                    {error, no_block};
                Limit when Limit =< Floor ->
                    {error, {intrinsic_exceeds_block_gas_limit, Floor, Limit}};
                Limit ->
                    Runner = fun(G) -> attempt_gas(Tx, BlockParam, Overrides, G) end,
                    case least_gas(Runner, Floor, Limit) of
                        {ok, Gas} -> {ok, Gas};
                        {error, Reason} -> {error, Reason}
                    end
            end
    end.

%% The call object's own `gas', if it has one. Read from the same map geth reads
%% it from -- the top-level `gas' of params[0] -- and not from an options object,
%% so a client that sets it in the call is obeyed.
gas_option(Tx) ->
    case maps:get(<<"gas">>, Tx, undefined) of
        undefined -> none;
        G when is_integer(G) -> {explicit, eth_hex:decode(G)};
        B when is_binary(B) -> {explicit, eth_hex:decode(B)};
        _ -> none
    end.

%% The floor below which no execution can succeed, because the EVM charges
%% intrinsic gas before the first instruction. `eth_tx:intrinsic_gas/2' is the one
%% schedule in this codebase, and it is the same one a transaction pays, so the
%% estimate cannot be lower than what the transaction would be charged.
%%
%% The fork is the one resolved from the block being simulated, by
%% block_gas_limit_and_fork/1. Passing nothing would fall back to the operator's
%% ETH_FORK pin, which is the documented weakening rather than an answer about
%% this block.
intrinsic_floor(Tx, Fork) ->
    try eth_tx:intrinsic_gas(Tx, Fork) catch _:_ -> 0 end.

%% The gas limit and the fork, from one fetch.
%%
%% These are asked together because they are read off the same block map and
%% asking separately would fetch it twice -- and `eth_call' has no block cache, so
%% a second fetch is a second round trip to whatever upstream is configured, on a
%% path (`eth_estimateGas') that a client may call in a loop. Two reads of the
%% same block that disagree would be worse than slow: the floor would be priced
%% under one fork's rules and the ceiling under another's.
block_gas_limit_and_fork(BlockParam) ->
    case fetch_block(BlockParam) of
        {ok, Block} ->
            try
                {ok, quantity_of(maps:get(<<"gasLimit">>, Block, undefined)),
                 fork_at(uint(maps:get(<<"number">>, Block)),
                         uint(maps:get(<<"timestamp">>, Block, 0)))}
            catch
                %% A block whose number or timestamp will not decode still has a
                %% gas limit worth answering with, so the fork falls back to the
                %% operator's pin rather than failing the whole estimate. The
                %% alternative is refusing to price a block we can otherwise read.
                _:_ -> {ok, quantity_of(maps:get(<<"gasLimit">>, Block, undefined)),
                        eth_fork_schedule:configured_fork()}
            end;
        _ ->
            undefined
    end.

%% One attempt, reduced to the three answers the search needs.
%%
%% Exported, and pure in its arguments, so the search can be tested against a
%% script of answers with no state, no chain and no upstream fetch. The EVM is
%% behind the fourth argument for exactly that reason -- a test for a binary
%% search that has to stand up a state trie to observe the halving pattern is a
%% test that will not be written.
-spec attempt_gas(map(), term(), map(), non_neg_integer()) ->
          ok | out_of_gas | {error, term()}.
attempt_gas(Tx, BlockParam, Overrides, Gas) ->
    WithGas = Tx#{<<"gas">> => eth_hex:encode_int(Gas)},
    case attempt(WithGas, BlockParam, Overrides) of
        %% A precompile is not an EVM execution -- it is charged for what it does
        %% and has no gas counter -- so it is classified here rather than by
        %% classify/1, which answers questions about an EVM run.
        {precompile, AddrInt, Data, Fork} ->
            precompile_attempt(AddrInt, Data, Gas, Fork);
        Outcome -> classify(Outcome)
    end.

%% The one place an execution outcome becomes an answer to "did it need more gas".
%%
%% Exported and pure, because this is where the estimation rules actually live and
%% the rules are not the interesting part -- the classification is. A revert is a
%% success here, which is the decision that is easy to get backwards: a revert
%% burns the gas it used, it is not an out-of-gas, and a client asking what a
%% call will cost is owed a number. The first version of this treated it as a
%% failure, so every reverting call was reported as "always fails" -- an error
%% where a figure was the correct answer, and one no test would have caught
%% without a reverting contract to run.
-spec classify(term()) -> ok | out_of_gas | {error, term()}.
classify({ok, _Out}) ->
    ok;
classify({revert, _Out}) ->
    ok;
classify({error, out_of_gas}) ->
    out_of_gas;
classify({error, Reason}) ->
    {error, Reason};
classify({no_block, Reason}) ->
    {error, Reason};
classify({no_env, Reason}) ->
    {error, Reason};
classify(Other) ->
    {error, {unexpected_outcome, Other}}.

%% A precompile is charged for what it does, so "did it run out of gas" is a
%% question about its cost, not about the EVM's gas counter. It fails for one
%% reason only -- an input it rejects -- and that reason is the answer.
precompile_attempt(AddrInt, Data, _Gas, Fork) ->
    case eth_evm_precompiles:precompile(AddrInt, Data, Fork) of
        {ok, _Out, _Cost} -> ok;
        unsupported -> {error, unsupported_precompile};
        {error, Reason} -> {error, Reason}
    end.

%% The least gas under which `Runner' does not report out-of-gas.
%%
%% `Lo' is assumed to fail and `Hi' is required to have been observed to succeed,
%% so the search is over a bracket that is known to contain the answer. It
%% converges on the *least* sufficient figure rather than any sufficient one,
%% which is what a gas estimate is: a client sending a transaction with more gas
%% than it needs pays the same and wastes the ceiling, and a validator charges
%% what the block says, so a loose estimate is a looser block.
-spec least_gas(fun((non_neg_integer()) -> ok | out_of_gas | {error, term()}),
                non_neg_integer(), non_neg_integer()) ->
          {ok, non_neg_integer()} | {error, term()}.
least_gas(Runner, Lo, Hi) ->
    case Runner(Hi) of
        ok -> search(Runner, Lo, Hi);
        {error, Reason} -> {error, Reason};
        out_of_gas -> {error, always_out_of_gas}
    end.

search(_Runner, Lo, Hi) when Hi - Lo =< 1 ->
    {ok, Hi};
search(Runner, Lo, Hi) ->
    Mid = Lo + (Hi - Lo) div 2,
    %% Monotonicity is what makes this a search: if Mid suffices, a smaller figure
    %% might too, so the answer is at or below Mid. If Mid ran out, it is at or
    %% above Mid. The first version had the two the other way round, which
    %% converges on `Hi' -- a gas limit rather than a gas estimate -- and returns
    %% it after eighteen probes having learned nothing. A test that named the
    %% expected figure caught it; an assertion on the *shape* of the result would
    %% have passed, because `{ok, 100000}' is a well-formed estimate.
    case Runner(Mid) of
        ok -> search(Runner, Lo, Mid);
        out_of_gas -> search(Runner, Mid, Hi);
        {error, _Reason} = E -> E
    end.

quantity_of(V) when is_integer(V), V >= 0 -> V;
quantity_of(V) when is_binary(V) ->
    try eth_hex:decode(V) catch _:_ -> undefined end;
quantity_of(_) -> undefined.

run_precompile(AddrInt, Data, Fork) ->
    case eth_evm_precompiles:precompile(AddrInt, Data, Fork) of
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
top_precompile(Tx, Fork) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined ->
            not_precompile;
        ToHex when is_binary(ToHex) ->
            W = eth_word:from_bytes(eth_state:address(ToHex)),
            %% Under the fork being simulated, which is not the operator's pin and is
            %% not "the newest fork". 0x09 answers this differently before and after
            %% Istanbul -- a pairing check at one, blake2f at the other, and an
            %% ordinary empty account at neither for a while -- so asking without a
            %% fork made `eth_estimateGas' on a historical block price a precompile
            %% the block has no contract at.
            case eth_evm_precompiles:is_precompile(W, Fork) of
                true -> {precompile, W, tx_data(Tx), Fork};
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
    %% Through `eth_tx:calldata/1'. This was a second, separately-written copy of the
    %% same rule and it happened to agree -- which is the good case, and still a second
    %% place for it to stop agreeing.
    eth_tx:calldata(Tx).

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
        Timestamp = uint(maps:get(<<"timestamp">>, Block, 0)),
        Env = #{number => Number,
                timestamp => Timestamp,
                %% The execution rules this block is subject to, resolved from
                %% its own number and timestamp. eth_evm:run/5 requires it: a
                %% call against a pre-Shanghai block must not run PUSH0, and a
                %% call against a Cancun one must. Simulating "latest" with the
                %% newest schedule would answer a question about block N with
                %% the rules of block N+k, and the only symptom would be a
                %% plausible answer.
                %%
                %% current_fork/3 answers {ok, Fork}, and the unwrapping is not
                %% optional: the {ok, Fork} tuple is not an atom, so it fails
                %% opcode_exists/2's is_atom/1 guard, every opcode reads as one
                %% the fork does not have, and every call halts on its first
                %% instruction with `undefined_opcode'.
                fork => fork_at(Number, Timestamp),
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

%% The fork a block executes under, as an atom. Anything other than {ok, _} --
%% which for current_fork/3 means "this network has no schedule, so use the
%% operator's ETH_FORK pin" -- is not silently turned into a fork. A call
%% against a block whose fork cannot be determined is a call this node cannot
%% simulate, and eth_evm:run/5 refusing a missing `fork' is the honest form of
%% that; guessing here would be the fabrication.
fork_at(Number, Timestamp) ->
    case eth_fork_schedule:current_fork(eth_fork_schedule:configured_network(),
                                        Number, Timestamp) of
        {ok, Fork} when is_atom(Fork) -> Fork;
        _ -> erlang:error({no_fork_for_block, Number, Timestamp})
    end.

param_hex(N) when is_integer(N) -> eth_hex:encode_int(N);
param_hex(Tag) when is_binary(Tag) -> Tag.
bin32(nil) -> <<0:256>>;
bin32(Hex) when is_binary(Hex) ->
    case byte_size(eth_state:data_bytes(Hex)) of
        32 -> eth_state:data_bytes(Hex);
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
                    H when is_binary(H) -> {ok, eth_state:data_bytes(H)};
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