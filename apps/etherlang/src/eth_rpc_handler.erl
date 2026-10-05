-module(eth_rpc_handler).

%% cowboy handler for the local JSON-RPC endpoint (spec at "POST /").
%%
%% Dispatch order:
%%   1. methods the node can answer locally (head/blocks it has stored),
%%   2. everything else -> proxied to the upstream node, result passed back
%%      verbatim (including upstream error objects).

-export([init/2]).

%% Post-merge totalDifficulty compat (EthStats agent validator compat).
%% Upstream omits totalDifficulty (post-merge geth-style), but classic
%% tooling requires the field to accept a block. Post-merge the value is
%% frozen at the terminal total difficulty, so serving the chain constant
%% is stating a protocol fact, not fabricating data. Gated to known
%% chains + post-merge heights only; storage is never touched (serve-time
%% presentation), pre-merge blocks and unknown chains pass through verbatim.
-define(SEPOLIA_CHAIN_ID, 11155111).
-define(SEPOLIA_MERGE_BLOCK, 1450409).
-define(SEPOLIA_TTD_HEX, <<"0x3c6568f12e8000">>). %% 17000000000000000

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case allowed(State, Req0) of
                true ->
                    {ok, Body, Req1} = cowboy_req:read_body(Req0, #{length => 50_000_000,
                                                                    period => 30000}),
                    Resp = handle_body(Body, State),
                    Req2 = cowboy_req:reply(200,
                                            #{<<"content-type">> => <<"application/json">>},
                                            Resp, Req1),
                    {ok, Req2, State};
                false ->
                    Req1 = cowboy_req:reply(429,
                        #{<<"content-type">> => <<"application/json">>},
                        thoas:encode(error_response(null, -32005,
                                                    <<"too many requests">>)),
                        Req0),
                    {ok, Req1, State}
            end;
        _ ->
            Req1 = cowboy_req:reply(405, #{<<"allow">> => <<"POST">>},
                                    <<"method not allowed">>, Req0),
            {ok, Req1, State}
    end.

%% Per-source request budget. No `limits' block (tests/legacy opts) = allow.
allowed(State, Req0) ->
    case maps:get(limits, State, undefined) of
        undefined ->
            true;
        #{tab := Tab, rate := Rate, burst := Burst} ->
            {IP, _} = cowboy_req:peer(Req0),
            eth_rate_limit:take(Tab, peer_key(IP), Rate, Burst)
    end.

peer_key({_, _, _, _} = IPv4) -> {ipv4, IPv4};
peer_key(IP) when is_tuple(IP) -> {ipv6, IP};
peer_key(_) -> unknown.

%% ---------------------------------------------------------------------------
%% JSON-RPC 2.0
%% ---------------------------------------------------------------------------

handle_body(Body, State) ->
    case thoas:decode(Body) of
        {ok, List} when is_list(List) ->
            case length(List) > maps:get(max_batch, State, 30) of
                true ->
                    thoas:encode(error_response(null, -32600,
                                                <<"batch too large">>));
                false ->
                    Results = [case check_api_key(M, State) of
                                    false ->
                                        error_response(
                                          maps:get(<<"id">>, M, null),
                                          -32500, <<"api_key required">>);
                                    true -> safe_handle_one(M, State)
                                end || M <- List],
                    thoas:encode(Results)
            end;
        {ok, Map} when is_map(Map) ->
            case check_api_key(Map, State) of
                false ->
                    thoas:encode(error_response(
                        maps:get(<<"id">>, Map, null), -32500,
                        <<"api_key required">>));
                true ->
                    thoas:encode(handle_one(Map, State))
            end;
        _ ->
            thoas:encode(error_response(null, -32700, <<"parse error">>))
    end.

%% API key auth: if RPC_API_KEY is set, every request must include
%% it as the "api_key" field inside params (standard JSON-RPC convention).
check_api_key(Map, State) ->
    case maps:get(api_key, State, undefined) of
        undefined -> true;
        "" -> true;
        Required ->
            Params = maps:get(<<"params">>, Map, #{}),
            case Params of
                #{<<"api_key">> := K} when is_binary(K), K =:= Required -> true;
                _ when is_list(Params) ->
                    lists:any(fun(#{<<"api_key">> := Kv}) when Kv =:= Required -> true;
                                 (_) -> false end, Params);
                _ -> false
            end
    end.

handle_one(Map, State) ->
    Id = maps:get(<<"id">>, Map, null),
    case maps:get(<<"method">>, Map, undefined) of
        undefined ->
            error_response(Id, -32600, <<"missing method">>);
        Method when is_binary(Method) ->
            %% Per-method rate limit check
            case check_rate_limit(Method, State) of
                false ->
                    error_response(Id, -32001, <<"rate limit exceeded">>);
                true ->
                    %% Strip api_key from params before dispatch
                    Map1 = case maps:get(api_key, State, undefined) of
                               undefined -> Map;
                               _ ->
                                   Params = maps:get(<<"params">>, Map, #{}),
                                   case is_map(Params) of
                                       true ->
                                           maps:put(<<"params">>,
                                                     maps:remove(<<"api_key">>, Params), Map);
                                       false -> Map
                                   end
                           end,
                    handle_one_inner(Method, Id, Map1, State)
            end;
        _ ->
            error_response(Id, -32600, <<"method must be a string">>)
    end.

handle_one_inner(Method, Id, Map, State) ->
    Params = maps:get(<<"params">>, Map, []),
    case dispatch(Method, Params, State) of
        {ok, Result} ->
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
              <<"result">> => Result};
        {error, {rpc_error, ErrMap}} when is_map(ErrMap) ->
            #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
              <<"error">> => ErrMap};
        {error, {upstream_error, Code, Msg}} ->
            error_response(Id, Code, Msg);
        {error, {invalid_params, Details}} ->
            error_response(Id, -32602, to_bin(Details));
        {error, {code, Code, Msg}} ->
            error_response(Id, Code, to_bin(Msg));
        {error, Reason} ->
            error_response(Id, -32000, to_bin(Reason))
    end.

%% Per-method rate limit: each method gets its own bucket
%% alongside the per-source bucket.
check_rate_limit(Method, State) ->
    case maps:get(limits, State, undefined) of
        undefined -> true;
        #{tab := Tab, rate := Rate, burst := Burst} ->
            %% Per-method rate limit: each method gets its own bucket
            eth_rate_limit:take(Tab, Method, Rate, Burst, Method)
    end.

%% Safe handler: catches crashes so batch responses never abort
%% the whole request (JSON-RPC spec compliance).
safe_handle_one(M, _State) when not is_map(M) ->
    {error, maps:get(<<"id">>, M, null), -32700, <<"invalid request: not an object">>};
safe_handle_one(M, State) ->
    try handle_one(M, State) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            logger:warning("etherlang: batch handler crash ~p:~p~n~p",
                           [Class, Reason, Stack]),
            {error, maps:get(<<"id">>, M, null), -32603, <<"internal error">>}
    end.

error_response(Id, Code, Msg) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code, <<"message">> => Msg}}.

%% ---------------------------------------------------------------------------
%% Dispatch
%% ---------------------------------------------------------------------------

dispatch(<<"eth_blockNumber">>, _Params, State) ->
    Chain = maps:get(chain, State, eth_chain),
    case eth_chain:head(Chain) of
        {N, _} -> {ok, eth_hex:encode_int(N)};
        undefined -> {error, chain_empty}
    end;

%% EIP-695 made the chain id mandatory, and every client checks it at startup to
%% confirm it is talking to the chain it thinks it is.
%%
%% It was answered by the catch-all, so the number came from `UPSTREAM_RPC_URL' --
%% it described the operator's configuration, not the chain this node executes, and
%% it would change if that variable did. The number is not hard to know:
%% `eth_fork_schedule:chain_id/0' is the same source the EVM's `CHAINID' opcode
%% reads, so this and the opcode cannot disagree.
dispatch(<<"eth_chainId">>, _Params, _State) ->
    {ok, eth_hex:encode_int(eth_fork_schedule:chain_id())};

%% --------------------------------------------------------------------------
%% Three methods with no clause here, which meant `-32601'. They are not on any
%% roadmap; they are what a stock Ethereum status tool asks for, and a node that
%% refuses them cannot be watched.
%%
%% **Measured, not assumed.** With these three absent, the eth-net-intelligence-api
%% agent could not build its stats for either node and the dashboard showed both
%% offline. It does not report the absence usefully: web3 0.x turned the `-32601'
%% into `Error: invalid argument 0: hex string without 0x prefix', which names a
%% *formatting* fault in this node's block responses -- and a scan of all 27 string
%% fields of `eth_getBlockByNumber' found none missing the prefix. **The hex
%% complaint was a symptom three layers downstream of an unsupported method**, which
%% is why the hex claim was wrong and reading it would have sent the fix to the
%% encoder instead of the dispatch table.
%% --------------------------------------------------------------------------

%% `net_version' is the chain id as a *decimal* string, not hex. Same source as
%% `eth_chainId' above, so the two cannot report different chains.
%%
%% **The result is a binary, and that is not incidental.** `integer_to_list/1' was the
%% first version and it answers an Erlang string -- a list of character codes -- where
%% every other result in this function is a binary, so the JSON encoder is handed a
%% different shape for this method alone. The test caught it as
%% `binary_to_list("11155111")`: an argument printed as `"11155111"' rather than
%% `<<"11155111">'`, which is the only place the difference is visible before the
%% encoder decides what to do with it.
dispatch(<<"net_version">>, _Params, _State) ->
    {ok, integer_to_binary(eth_fork_schedule:chain_id())};

dispatch(<<"eth_gasPrice">>, _Params, State) ->
    Chain = maps:get(chain, State, eth_chain),
    case eth_rpc_projection:next_base_fee_for_head(Chain) of
        {ok, Fee} ->
            {ok, eth_hex:encode_int(Fee)};
        {error, no_local_head} ->
            %% The same shape and the same reason as `eth_maxPriorityFeePerGas'
            %% below: this node holds no head, so it has no evidence about the next
            %% block's base fee. Another node does. A fallback with a reason is a
            %% different thing from a refusal, and this is the former.
            proxy(<<"eth_gasPrice">>, [])
    end;

dispatch(<<"net_peerCount">>, _Params, _State) ->
    %% **Peers this node is actually talking to, not the size of a table.**
    %% The predicate is `eth_peer:eth_ready_peer/1's, verbatim, so the number a
    %% dashboard shows and the peer this node would sync from cannot disagree.
    %%
    %% `eth_peer:status/0' would have been cheaper -- it is a map size -- but it counts
    %% conns that have not finished handshaking and conns that are dead. Measured on
    %% two live nodes: it reported `peers => 1' while `eth_peer:peers/0' answered
    %% `{error, down}' for that single entry, so the cheap number counted something
    %% nothing could reach.
    {ok, eth_hex:encode_int(eth_peer:eth_peer_count())};

%% EIP-3675: the Merge took uncles out of the block header. A post-Merge block has
%% none, so the count is `0` and the uncle is `null` -- and on this chain, which
%% merged at genesis, that is true at *every* height it has. Both are therefore
%% constants here, answered without a lookup and without asking anyone.
%%
%% By number it is unconditional, and that is not a shortcut: resolving the tag
%% would tell us nothing, because the answer is the same whatever height is asked
%% for. The tag is still validated, so a malformed one is still a bad-params error
%% rather than a `0` for a block that does not exist.
%%
%% By *hash* it is not unconditional. A hash this node does not hold may name a
%% pre-Merge block on some other chain, which really did carry uncles, and `0`
%% would then be a claim about a block this node has never seen. Those refuse,
%% naming the reason, rather than answering.
dispatch(<<"eth_getUncleCountByBlockNumber">>, [Tag], State) ->
    case uncle_number_tag(State, Tag) of
        ok -> {ok, <<"0x0">>};
        {error, Why} -> {error, Why}
    end;

dispatch(<<"eth_getUncleByBlockNumberAndIndex">>, [Tag, _Index], State) ->
    case uncle_number_tag(State, Tag) of
        ok -> {ok, null};
        {error, Why} -> {error, Why}
    end;

dispatch(<<"eth_getUncleCountByBlockHash">>, [Hash], State) ->
    case uncle_hash_known(State, Hash) of
        ok -> {ok, <<"0x0">>};
        {error, Why} -> {error, Why}
    end;

dispatch(<<"eth_getUncleByBlockHashAndIndex">>, [Hash, _Index], State) ->
    case uncle_hash_known(State, Hash) of
        ok -> {ok, null};
        {error, Why} -> {error, Why}
    end;

dispatch(<<"eth_syncing">>, _Params, State) ->
    Sync = maps:get(sync, State, eth_sync),
    case try eth_sync:status(Sync) catch _:_ -> error end of
        false -> {ok, false};
        Map when is_map(Map) -> {ok, Map};
        _ -> {ok, false}
    end;

dispatch(<<"web3_clientVersion">>, _Params, _State) ->
    {ok, <<"etherlang/0.7.2 (erlang)">>};

dispatch(<<"eth_getVersion">>, _Params, _State) ->
    {ok, <<"etherlang/0.7.2 (erlang)">>};

dispatch(<<"eth_coinbase">>, _Params, _State) ->
    %% No miner/signer configured in v1; report the zero address.
    {ok, <<"0x0000000000000000000000000000000000000000">>};

dispatch(<<"eth_mining">>, _Params, _State) ->
    {ok, false};

dispatch(<<"eth_hashrate">>, _Params, _State) ->
    {ok, <<"0x0">>};

dispatch(<<"eth_getBlockByNumber">>, [NumHex, Full], State) when
        is_binary(NumHex), is_boolean(Full) ->
    Chain = maps:get(chain, State, eth_chain),
    Num = eth_rpc_projection:resolve_block_number(Chain, NumHex),
    case eth_chain:get_by_number(Chain, Num) of
        {ok, _Block, FullStored} when Full andalso not FullStored ->
            proxy(<<"eth_getBlockByNumber">>, [num_or_tag(NumHex, Num), Full]);
        {ok, Block, _} ->
            {ok, with_td_compat(Block)};
        not_found ->
            proxy(<<"eth_getBlockByNumber">>, [num_or_tag(NumHex, Num), Full])
    end;

dispatch(<<"eth_getBlockByHash">>, [Hash, Full], State) when
        is_binary(Hash), is_boolean(Full) ->
    Chain = maps:get(chain, State, eth_chain),
    case eth_chain:get_by_hash(Chain, Hash) of
        {ok, _Block, FullStored} when Full andalso not FullStored ->
            proxy(<<"eth_getBlockByHash">>, [Hash, Full]);
        {ok, Block, _} ->
            {ok, with_td_compat(Block)};
        not_found ->
            proxy(<<"eth_getBlockByHash">>, [Hash, Full])
    end;

dispatch(<<"eth_getBlockTransactionCountByNumber">>, [NumHex], State) ->
    Chain = maps:get(chain, State, eth_chain),
    Num = eth_rpc_projection:resolve_block_number(Chain, NumHex),
    case eth_chain:get_by_number(Chain, Num) of
        {ok, Block, _} ->
            {ok, eth_hex:encode_int(length(maps:get(<<"transactions">>, Block, [])))};
        not_found ->
            proxy(<<"eth_getBlockTransactionCountByNumber">>, [num_or_tag(NumHex, Num)])
    end;

dispatch(<<"eth_getBlockTransactionCountByHash">>, [Hash], State) ->
    Chain = maps:get(chain, State, eth_chain),
    case eth_chain:get_by_hash(Chain, Hash) of
        {ok, Block, _} ->
            {ok, eth_hex:encode_int(length(maps:get(<<"transactions">>, Block, [])))};
        not_found ->
            proxy(<<"eth_getBlockTransactionCountByHash">>, [Hash])
    end;

dispatch(<<"eth_getTransactionByBlockNumberAndIndex">>, [NumHex, IndexHex], State) ->
    Chain = maps:get(chain, State, eth_chain),
    Num = eth_rpc_projection:resolve_block_number(Chain, NumHex),
    case eth_chain:get_by_number(Chain, Num) of
        {ok, Block, true} ->
            Txs = maps:get(<<"transactions">>, Block, []),
            Idx = eth_hex:decode(IndexHex),
            case length(Txs) > Idx of
                true -> {ok, lists:nth(Idx + 1, Txs)};
                false -> {ok, null}
            end;
        _ ->
            proxy(<<"eth_getTransactionByBlockNumberAndIndex">>,
                  [num_or_tag(NumHex, Num), IndexHex])
    end;

dispatch(<<"eth_call">>, Params, _State) ->
    case eth_config:evm_enabled() of
        false ->
            proxy(<<"eth_call">>, Params);
        true ->
            case eth_call:call(Params) of
                {ok, Result} ->
                    {ok, Result};
                {error, {rpc_error, ErrMap}} when is_map(ErrMap) ->
                    {error, {rpc_error, ErrMap}};
                {error, {bad_params, Why}} ->
                    {error, {bad_params, Why}};
                _ ->
                    proxy(<<"eth_call">>, Params)
            end
    end;

dispatch(<<"eth_getTransactionReceipt">>, [TxHash], State) when is_binary(TxHash) ->
    Chain = maps:get(chain, State, eth_chain),
    case local_receipt(Chain, TxHash) of
        {ok, Receipt} -> {ok, Receipt};
        not_found -> proxy(<<"eth_getTransactionReceipt">>, [TxHash])
    end;

dispatch(<<"eth_getBalance">>, [Addr, _Tag], State) when is_binary(Addr) ->
    case local_account_field(State, Addr, balance) of
        {ok, V} -> {ok, V};
        not_found -> proxy(<<"eth_getBalance">>, [Addr, _Tag])
    end;

dispatch(<<"eth_getTransactionCount">>, [Addr, _Tag], State) when is_binary(Addr) ->
    case local_account_field(State, Addr, nonce) of
        {ok, V} -> {ok, V};
        not_found -> proxy(<<"eth_getTransactionCount">>, [Addr, _Tag])
    end;

dispatch(<<"eth_getCode">>, [Addr, _Tag], State) when is_binary(Addr) ->
    case local_code(State, Addr) of
        {ok, V} -> {ok, V};
        not_found -> proxy(<<"eth_getCode">>, [Addr, _Tag])
    end;

dispatch(<<"eth_getStorageAt">>, [Addr, Slot, _Tag], State)
  when is_binary(Addr), is_binary(Slot) ->
    case local_storage(State, Addr, Slot) of
        {ok, V} -> {ok, V};
        not_found -> proxy(<<"eth_getStorageAt">>, [Addr, Slot, _Tag])
    end;

dispatch(<<"eth_sendRawTransaction">>, [RawHex], State) when is_binary(RawHex) ->
    Pool = maps:get(pool, State, eth_txpool),
    case parse_raw_tx(RawHex) of
        {ok, Bin} ->
            case (try eth_txpool:add_raw(Pool, Bin) catch _:_ -> {error, no_pool} end) of
                {ok, Hash} ->
                    eth_peer:broadcast([eth_hex:must_decode_bytes(Hash)]),
                    {ok, Hash};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;

dispatch(<<"eth_getLogs">>, [Filter], State) when is_map(Filter) ->
    Chain = maps:get(chain, State, eth_chain),
    case local_logs(Chain, Filter) of
        {ok, Logs} -> {ok, Logs};
        {error, _} -> proxy(<<"eth_getLogs">>, [Filter])
    end;

%% ===========================================================================
%% Methods that were proxied and are now answered from what this node holds
%% ===========================================================================
%%
%% Every clause below follows the same shape: answer locally when this node holds
%% the data, and proxy when it does not. None of them invents a value, and the
%% comments say what the local answer is derived from -- because a local answer that
%% is a *guess* would be worse than the proxy it replaced, and the only way to keep
%% that true is to be explicit about the derivation.

dispatch(<<"eth_accounts">>, _Params, _State) ->
    %% "Returns a list of addresses owned by client."
    %%
    %% An empty array, and it is the correct answer rather than a placeholder. This
    %% node has no keystore, no unlocked account and no signer: it relays
    %% transactions other people signed and it builds blocks for a fee recipient the
    %% consensus client named. So the set of accounts it owns is empty, and `[]' is
    %% that set. Proxied, this returned the *upstream* node's accounts, which is a
    %% different node's answer to a question about this one.
    {ok, []};

dispatch(<<"eth_getBlockReceipts">>, [BlockParam], State) ->
    Chain = maps:get(chain, State, eth_chain),
    case resolve_block(Chain, BlockParam) of
        {ok, Num} ->
            case eth_rpc_projection:block_receipts(Chain, Num) of
                {ok, Receipts} ->
                    {ok, Receipts};
                {error, {pruned_history, _Num}} ->
                    %% The specification names this case on this method: 4444, "Pruned
                    %% history unavailable". The block is held; its receipts are not. A
                    %% block this node never fetched receipts for is exactly that, and
                    %% `null' would be indistinguishable from "this block has no
                    %% transactions" -- a different fact about a real block, and one a
                    %% client indexing the chain would act on.
                    {error, {code, 4444, <<"pruned history unavailable">>}};
                {error, not_found} ->
                    proxy(<<"eth_getBlockReceipts">>, [BlockParam])
            end;
        {error, _} ->
            proxy(<<"eth_getBlockReceipts">>, [BlockParam])
    end;

dispatch(<<"eth_getTransactionByHash">>, [TxHash], State)
  when is_binary(TxHash) ->
    Chain = maps:get(chain, State, eth_chain),
    case eth_rpc_projection:transaction_by_hash(Chain, TxHash) of
        {ok, Tx} -> {ok, Tx};
        {error, not_found} -> proxy(<<"eth_getTransactionByHash">>, [TxHash])
    end;

%% The ByHashAndIndex pair of the method above, added because it shares the
%% projection: the stored transaction object plus the same three positional fields.
%% Phase 6 lists it as missing and it was missing for the same reason -- nothing
%% projected a stored transaction -- so it cost two lines here.
dispatch(<<"eth_getTransactionByBlockHashAndIndex">>, [Hash, IndexHex], State)
  when is_binary(Hash), is_binary(IndexHex) ->
    Chain = maps:get(chain, State, eth_chain),
    case eth_chain:get_by_hash(Chain, norm(Hash)) of
        {ok, Block, _} when is_map(Block) ->
            case index_of(Chain, Block, IndexHex) of
                {ok, Tx} -> {ok, Tx};
                {error, _} = E -> E
            end;
        _ ->
            proxy(<<"eth_getTransactionByBlockHashAndIndex">>, [Hash, IndexHex])
    end;

dispatch(<<"eth_feeHistory">>, [CountHex, Newest, Percentiles], State) ->
    Chain = maps:get(chain, State, eth_chain),
    Count = quantity_of(CountHex),
    case eth_rpc_projection:fee_history(Chain, Count, Newest, Percentiles) of
        {ok, Result} ->
            {ok, Result};
        {error, invalid_block_count} ->
            %% No oldestBlock exists for a zero-block range and the field is
            %% required, so the argument is what is wrong. -32602 rather than a
            %% result, because a convention here would be a height this node invented.
            {error, {code, -32602, <<"invalid block count">>}};
        {error, invalid_percentiles} ->
            {error, {code, -32602, <<"invalid reward percentiles">>}};
        {error, {newest_not_held, N}} ->
            %% The block is real and this node simply does not hold it. Another node
            %% will, so this is a fallback and not a refusal.
            proxy(<<"eth_feeHistory">>,
                  [CountHex, eth_hex:encode_int(N), Percentiles]);
        {error, _} = E ->
            E
    end;

dispatch(<<"eth_maxPriorityFeePerGas">>, _Params, _State) ->
    case eth_block_builder:suggested_tip() of
        {ok, Tip} -> {ok, eth_hex:encode_int(Tip)};
        undefined ->
            %% This node's pool is empty or holds nothing it can price, so it has no
            %% evidence about the network's next block. Answering 0 would tell a
            %% client the next block pays no tip, which is a claim about the chain
            %% derived from a fact about this node.
            proxy(<<"eth_maxPriorityFeePerGas">>, [])
    end;

dispatch(<<"eth_getProof">>, [Address, Slots], State) ->
    proof_dispatch(Address, Slots, latest, State, 2);
dispatch(<<"eth_getProof">>, [Address, Slots, Block], State) ->
    proof_dispatch(Address, Slots, Block, State, 3);

dispatch(<<"eth_estimateGas">>, Params, _State) ->
    case eth_config:evm_enabled() of
        false ->
            proxy(<<"eth_estimateGas">>, Params);
        true ->
            case eth_call:estimate_gas(Params) of
                {ok, Gas} -> {ok, eth_hex:encode_int(Gas)};
                {error, {bad_params, Why}} -> {error, {bad_params, Why}};
                {error, Reason} -> {error, {code, -32000, to_bin(Reason)}}
            end
    end;

%% A method with no clause here is **refused**, not forwarded.
%%
%% It used to be forwarded, and that is the single most misleading thing this
%% handler could do: the set of questions this node can answer is not the set of
%% questions it answers. A client asking `eth_getUncleCountByBlockNumber' of this
%% node was told the answer by a *different* node, and nothing in the response said
%% so. The same held for `eth_chainId', where the answer came from whatever
%% `UPSTREAM_RPC_URL' happened to point at -- so it tracked the operator's
%% configuration rather than the chain this node executes.
%%
%% `-32601' is the JSON-RPC 2.0 code for "method not found", and it is the honest
%% answer: this node does not implement the method. The message names the method so
%% the refusal is debuggable from a client's log rather than merely absent.
%%
%% The *deliberate* fallbacks are unaffected and are not in this clause: several
%% methods above proxy on purpose, and only after a documented local attempt has
%% come up empty -- `eth_getBalance' when the account is not in the local overlay,
%% `eth_estimateGas' when the EVM is disabled. A fallback with a reason is
%% different in kind from answering everything.
dispatch(Method, _Params, _State) ->
    {error, {code, -32601, method_not_supported(Method)}}.

method_not_supported(Method) when is_binary(Method) ->
    iolist_to_binary(
      io_lib:format("method not supported by this node: ~s. It implements the "
                    "methods in its own dispatch/3; a catch-all used to forward "
                    "unknown methods upstream, which meant the answer came from a "
                    "different node and nothing in the response said so.",
                    [Method]));
method_not_supported(Method) ->
    iolist_to_binary(io_lib:format("method not supported by this node: ~p", [Method])).

%% `BlockNumberOrTagOrHash' -- the parameter of eth_getBlockReceipts -- is the tag
%% vocabulary *or* a 32-byte hash. A hash is not a height, so it cannot go through
%% resolve_block_number/2 at all: that decodes any binary as a QUANTITY, and
%% `eth_hex:decode/1' on a 32-byte hash yields a 256-bit integer. Passing one there
%% would resolve the requested block to an arbitrary height, and a client asking for
%% "the receipts of block 0x1541..." would be served some other block's receipts
%% without an error. So a 32-byte value is recognised as a hash and routed by hash,
%% and only a tag or a short hex string is a height.
resolve_block(Chain, Param) ->
    case is_hash(Param) of
        true ->
            case eth_chain:get_by_hash(Chain, norm(Param)) of
                {ok, Block, _} when is_map(Block) ->
                    case quantity_of(maps:get(<<"number">>, Block, undefined)) of
                        undefined -> {error, no_number};
                        N -> {ok, N}
                    end;
                _ ->
                    {error, not_found}
            end;
        false ->
            {ok, eth_rpc_projection:resolve_block_number(Chain, Param)}
    end.

%% 32 bytes is a hash and nothing else in this parameter's grammar: a height is a
%% QUANTITY and a tag is a word. There is no overlap, so the width alone decides.
is_hash(V) when is_binary(V) ->
    case eth_hex:decode_bytes(V) of
        {ok, Bytes} -> byte_size(Bytes) =:= 32;
        error -> false
    end;
is_hash(_) -> false.

%% eth_chain is keyed on the `hash' field of the block map it stores, which is the
%% 0x-prefixed lower-case hex string of an eth_getBlockByNumber response. A client
%% may send the upper-case form, and that is the same block.
norm(H) when is_binary(H) ->
    case H of
        <<"0x", Rest/binary>> -> <<"0x", (string:lowercase(Rest))/binary>>;
        _ -> <<"0x", (string:lowercase(H))/binary>>
    end;
norm(H) when is_integer(H) -> eth_hex:encode_int(H).

%% An index within a held block. `null' for an index the block does not have -- the
%% specification's `notFound' -- and 4444 for a block stored without its transaction
%% list, which is this method's own "pruned history unavailable".
index_of(Chain, Block, IndexHex) ->
    Num = quantity_of(maps:get(<<"number">>, Block, undefined)),
    case is_integer(Num) of
        false ->
            {ok, null};
        true ->
            case eth_rpc_projection:transaction_at(Chain, Num,
                                                   quantity_of(IndexHex)) of
                {ok, Tx} -> {ok, Tx};
                {error, {pruned_history, _N}} ->
                    {error, {code, 4444, <<"pruned history unavailable">>}};
                {error, not_found} ->
                    {ok, null}
            end
    end.

%% `AccountProof' is `additionalProperties: false' with seven required fields, every
%% one a fact about a state trie. This node's reads come from upstream by default and
%% it holds no trie to prove against, and a peer sends balances rather than the RLP
%% nodes a proof is made of -- so there is no proof it could construct. Another node
%% holds the state, so this proxies rather than answering.
proof_dispatch(Address, Slots, Block, _State, Arity) ->
    Params = [Address, Slots, Block],
    case is_list(Slots) andalso is_binary(Address) of
        false ->
            {error, {code, -32602, <<"invalid params">>}};
        true ->
            case eth_rpc_projection:account_proof(Address, Slots, Block) of
                {ok, Proof} -> {ok, Proof};
                {error, {state_not_local, _}} ->
                    proxy(<<"eth_getProof">>, lists:sublist(Params, Arity));
                {error, account_not_local} ->
                    proxy(<<"eth_getProof">>, lists:sublist(Params, Arity));
                {error, _} = E ->
                    E
            end
    end.

quantity_of(V) when is_integer(V), V >= 0 -> V;
quantity_of(V) when is_binary(V) ->
    try eth_hex:decode(V) catch _:_ -> undefined end;
quantity_of(_) -> undefined.

%% Local account field (balance/nonce) from the snap store, keyed by
%% address hash. Values stored as account RLP; quantities re-encoded.
local_account_field(State, Addr, Field) ->
    Store = maps:get(store, State, eth_statestore),
    AHash = eth_keccak:hash(addr_bin(Addr)),
    case (try eth_statestore:get_account(Store, AHash) catch _:_ -> not_found end) of
        {ok, AcctRLP} ->
            case eth_rlp:decode(AcctRLP) of
                {ok, Acct, <<>>} when is_list(Acct) ->
                    Idx = case Field of
                              balance -> 1;
                              nonce -> 0
                          end,
                    {ok, eth_hex:encode_int(qty(lists:nth(Idx + 1, Acct)))};
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

local_code(State, Addr) ->
    Store = maps:get(store, State, eth_statestore),
    AHash = eth_keccak:hash(addr_bin(Addr)),
    case (try eth_statestore:get_account(Store, AHash) catch _:_ -> not_found end) of
        {ok, AcctRLP} ->
            case eth_rlp:decode(AcctRLP) of
                {ok, [_, _, _, CodeHash], <<>>} ->
                    case (try eth_statestore:get_code(Store, CodeHash)
                          catch _:_ -> not_found end) of
                        {ok, Code} -> {ok, bin0x(Code)};
                        _ -> not_found
                    end;
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

local_storage(State, Addr, Slot) ->
    Store = maps:get(store, State, eth_statestore),
    try
        AHash = eth_keccak:hash(addr_bin(Addr)),
        SlotHash = eth_keccak:hash(slot_bin(Slot)),
        case eth_statestore:get_storage(Store, AHash, SlotHash) of
            {ok, ValRLP} ->
                case eth_rlp:decode(ValRLP) of
                    {ok, Val, <<>>} -> {ok, eth_hex:encode_int(qty(Val))};
                    _ -> not_found
                end;
            _ ->
                not_found
        end
    catch _:_ ->
        not_found
    end.

addr_bin(<<"0x", R/binary>>) ->
    try binary:decode_hex(R) catch _:_ -> <<>> end;
addr_bin(B) when is_binary(B), byte_size(B) =:= 20 -> B;
addr_bin(_) -> <<>>.

slot_bin(<<"0x", R/binary>>) ->
    try pad32(binary:decode_hex(R)) catch _:_ -> error end;
slot_bin(_) -> error.

pad32(B) when byte_size(B) =:= 32 -> B;
pad32(B) when byte_size(B) < 32 ->
    Pad = 32 - byte_size(B),
    <<0:(Pad * 8), B/binary>>.

qty(I) when is_integer(I) -> I;
qty(B) when is_binary(B), byte_size(B) =:= 0 -> 0;
qty(B) when is_binary(B) -> binary:decode_unsigned(B);
qty(_) -> 0.

bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

%% Upstream passthrough.
proxy(Method, Params) ->
    case eth_rpc_client:call(Method, Params) of
        {ok, Result} -> {ok, Result};
        {error, {rpc_error, Err}} when is_map(Err) ->
            Code = maps:get(<<"code">>, Err, -32000),
            Msg = maps:get(<<"message">>, Err, <<"upstream error">>),
            {error, {code, Code, Msg}};
        {error, {bad_decode, DecErr}} ->
            {error, {code, -32700, io_lib:format("decode error: ~p", [DecErr])}};
        {error, {bad_response, _RespBin}} ->
            {error, {code, -32700, <<"bad upstream response">>}};
        {error, {http, Code}} ->
            {error, {code, Code, <<"upstream HTTP error">>}};
        {error, Reason} ->
            %% Transport/HTTP errors get a distinct code, not -32000.
            {error, {code, -32603, io_lib:format("~p", [Reason])}}
    end.

%% Local receipt: tx index -> block -> stored receipts -> response with
%% block/tx context attached. `from' is null until ecrecover lands.
local_receipt(Chain, TxHash) ->
    case (try eth_chain:tx_block(Chain, TxHash) catch _:_ -> not_found end) of
        {ok, Num} ->
            case (try eth_chain:get_by_number(Chain, Num) catch _:_ -> not_found end) of
                {ok, Block, true} ->
                    case (try eth_chain:receipts(Chain, Num) catch _:_ -> not_found end) of
                        {ok, Receipts} ->
                            find_receipt(Block, Num, TxHash, Receipts);
                        _ ->
                            not_found
                    end;
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

find_receipt(Block, Num, TxHash, Receipts) ->
    Txs = maps:get(<<"transactions">>, Block, []),
    BlockHash = maps:get(<<"hash">>, Block, undefined),
    find_idx(BlockHash, Num, TxHash, lists:zip(Txs, Receipts), 0).

find_idx(BlockHash, Num, TxHash, Pairs, Idx) ->
    find_idx(BlockHash, Num, TxHash, Pairs, Idx, 0).

find_idx(_, _, _, [], _, _) ->
    not_found;
find_idx(BlockHash, Num, TxHash, [{Tx, R} | Rest], Idx, PrevCum)
  when is_map(Tx), is_map(R) ->
    Cum = cum_value(R),
    TxGas = Cum - PrevCum,
    case maps:get(<<"hash">>, Tx, undefined) of
        TxHash ->
            {ok, eth_rpc_projection:receipt_response(
                   BlockHash, Num, TxHash, Idx, Tx, R, Cum, TxGas)};
        _ ->
            find_idx(BlockHash, Num, TxHash, Rest, Idx + 1, Cum)
    end;
find_idx(BlockHash, Num, TxHash, [_ | Rest], Idx, PrevCum) ->
    find_idx(BlockHash, Num, TxHash, Rest, Idx + 1, PrevCum).

cum_value(R) ->
    to_int(maps:get(<<"cumulative_gas_used">>, R,
                    maps:get(<<"cumulativeGasUsed">>, R, 0))).

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) ->
    try eth_hex:decode(B) catch _:_ -> 0 end;
to_int(_) -> 0.

%% Local log filter over stored receipts. Range capped to keep scans bounded.
-define(MAX_LOG_RANGE, 1024).

local_logs(Chain, Filter) ->
    try
        {From, To} = log_range(Chain, Filter),
        case To - From =< ?MAX_LOG_RANGE of
            false -> {error, range_too_wide};
            true ->
                Addrs = log_addrs(maps:get(<<"address">>, Filter, undefined)),
                Topics = maps:get(<<"topics">>, Filter, []),
                Logs = lists:append(
                         [block_logs(Chain, N, Addrs, Topics) ||
                             N <- lists:seq(From, To)]),
                {ok, Logs}
        end
    catch _:_ ->
        {error, bad_filter}
    end.

%% One tag vocabulary, through eth_rpc_projection:resolve_block_number/2, for the
%% same reason every other method that takes a BlockNumberOrTag goes through it. This
%% function had its own copy -- `log_num/2', beside a `resolve_num/2' with identical
%% clauses -- and the two were free to drift, so `finalized' could come to mean one
%% height in a log filter and another in a block lookup.
log_range(Chain, Filter) ->
    HeadN = eth_rpc_projection:resolve_block_number(Chain, <<"latest">>),
    From = eth_rpc_projection:resolve_block_number(
             Chain, maps:get(<<"fromBlock">>, Filter, <<"latest">>)),
    To = eth_rpc_projection:resolve_block_number(
           Chain, maps:get(<<"toBlock">>, Filter, <<"latest">>)),
    {max(From, 0), min(To, HeadN)}.

log_addrs(undefined) -> any;
log_addrs(A) when is_binary(A) -> [norm_hex(A)];
log_addrs(L) when is_list(L) -> [norm_hex(A) || A <- L].

block_logs(Chain, N, Addrs, Topics) ->
    case (try eth_chain:get_by_number(Chain, N) catch _:_ -> not_found end) of
        {ok, Block, true} ->
            case (try eth_chain:receipts(Chain, N) catch _:_ -> not_found end) of
                {ok, Receipts} when is_list(Receipts) ->
                    BlockHash = maps:get(<<"hash">>, Block, undefined),
                    Txs = maps:get(<<"transactions">>, Block, []),
                    %% Paired by position, up to the shorter of the two lists.
                    %%
                    %% This was `lists:zip(lists:zip(Txs, Receipts), ...)', and
                    %% `lists:zip/2' requires the lists to be the *same length*. A
                    %% block with three transactions and no stored receipts -- which is
                    %% every block this node synced without fetching receipts -- raised
                    %% function_clause, and `local_logs/2' catches everything and returns
                    %% `{error, bad_filter}', so the whole filter fell back to the
                    %% upstream. The failure was invisible: `eth_getLogs' answered, from
                    %% another node, and a caller comparing the two results would see a
                    %% difference in coverage with nothing in the response to explain
                    %% it. A block whose receipts are partly stored contributes the
                    %% receipts it has and says nothing about the rest.
                    N2 = min(length(Txs), length(Receipts)),
                    lists:append(
                      [receipt_logs(BlockHash, N, lists:nth(I + 1, Txs),
                                    lists:nth(I + 1, Receipts), I, Addrs, Topics)
                       || I <- lists:seq(0, N2 - 1)]);
                _ ->
                    []
            end;
        _ ->
            []
    end.

receipt_logs(_BlockHash, _N, Tx, _R, _Idx, _Addrs, _Topics) when not is_map(Tx) ->
    [];
receipt_logs(BlockHash, N, Tx, R, Idx, Addrs, Topics) when is_map(R) ->
    TxHash = maps:get(<<"hash">>, Tx, undefined),
    Logs = eth_rpc_projection:enrich_logs(maps:get(<<"logs">>, R, []),
                                         BlockHash, N, TxHash, Idx, 0),
    [L || L <- Logs, log_matches(L, Addrs, Topics)].

log_matches(Log, any, []) -> is_map(Log);
log_matches(Log, Addrs, Topics) ->
    addr_matches(maps:get(<<"address">>, Log, undefined), Addrs) andalso
    topics_match(maps:get(<<"topics">>, Log, []), Topics).

addr_matches(_, any) -> true;
addr_matches(A, Addrs) when is_binary(A) ->
    lists:member(norm_hex(A), Addrs);
addr_matches(_, _) -> false.

topics_match(_, []) -> true;
topics_match(Got, [null | Rest]) ->
    topics_match(tl_safe(Got), Rest);
topics_match(Got, [F | Rest]) when is_binary(F) ->
    case Got of
        [G | Gs] -> norm_hex(G) =:= norm_hex(F) andalso topics_match(Gs, Rest);
        [] -> false
    end;
topics_match(Got, [Fs | Rest]) when is_list(Fs) ->
    case Got of
        [G | Gs] ->
            lists:any(fun(F) -> norm_hex(G) =:= norm_hex(F) end, Fs) andalso
            topics_match(Gs, Rest);
        [] -> false
    end;
topics_match(_, _) -> false.

tl_safe([_ | T]) -> T;
tl_safe([]) -> [].

norm_hex(B) when is_binary(B) -> string:lowercase(B);
norm_hex(Other) -> Other.

parse_raw_tx(<<"0x", Rest/binary>>) -> parse_raw_tx(Rest);
parse_raw_tx(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try {ok, binary:decode_hex(Bin)}
    catch _:_ -> {error, bad_tx_hex}
    end;
parse_raw_tx(_) ->
    {error, bad_tx_hex}.


%% Resolve a block-number reference ("latest"/"earliest"/"pending"/
%% Resolving a tag to a height is eth_rpc_projection:resolve_block_number/2, for
%% every method that takes one. This stays only to hand the *original* tag to
%% upstream when a local lookup misses, so the peer resolves the tag the client
%% wrote rather than one this node re-spelled.
num_or_tag(Hex, _Num) -> Hex.

%% A block tag or number this node recognises, for the uncle methods.
uncle_number_tag(State, Tag) ->
    Chain = maps:get(chain, State, eth_chain),
    try eth_rpc_projection:resolve_block_number(Chain, Tag) of
        N when is_integer(N) -> ok
    catch
        _:_ -> {error, {code, -32602, <<"invalid block number or tag">>}}
    end.

%% Whether this node holds the block a hash names. It does not have to be
%% post-Merge for the answer to be `0` -- the node's chain is -- but it does have to
%% be a block this node can speak about at all.
%% The hash arrives as the 0x-hex string the specification puts on the wire and
%% the chain store is keyed by, and is passed through unchanged -- the same
%% convention `eth_getBlockByHash/3' already uses. The first version of this also
%% accepted 32 *raw* bytes, which cannot arrive: a JSON string is text, and
%% `thoas:encode/1' rejects a byte above 0x7f outright, so the branch was
%% unreachable from the only caller there is.
uncle_hash_known(State, Hash) when is_binary(Hash) ->
    Chain = maps:get(chain, State, eth_chain),
    case eth_hex:is_hex(Hash) of
        false ->
            {error, {code, -32602, <<"invalid block hash">>}};
        true ->
            case eth_chain:get_by_hash(Chain, Hash) of
                {ok, _Map, _Full} ->
                    ok;
                _ ->
                    {error, {code, -32001,
                             <<"block not held locally: this node answers uncle "
                               "counts only for blocks it has, because a hash it "
                               "does not hold may name a pre-Merge block that "
                               "really did have uncles">>}}
            end
    end.

%% Serve-time totalDifficulty compat (see defines at top of file). Only
%% fills the field when absent AND the block is provably post-merge on a
%% known chain; everything else passes through untouched.
with_td_compat(Block) when is_map(Block) ->
    case maps:is_key(<<"totalDifficulty">>, Block) of
        true ->
            Block;
        false ->
            case {eth_state:chain_id(), eth_header:number(Block)} of
                {?SEPOLIA_CHAIN_ID, N} when is_integer(N), N >= ?SEPOLIA_MERGE_BLOCK ->
                    Block#{<<"totalDifficulty">> => ?SEPOLIA_TTD_HEX};
                _ ->
                    Block
            end
    end;
with_td_compat(Other) ->
    Other.

to_bin(Term) when is_binary(Term) -> Term;
to_bin(Term) when is_list(Term) -> list_to_binary(Term);
to_bin(Term) when is_atom(Term) -> atom_to_binary(Term, utf8);
to_bin(Term) when is_integer(Term) -> integer_to_binary(Term);
to_bin(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).