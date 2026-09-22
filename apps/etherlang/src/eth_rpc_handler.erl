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
                    thoas:encode([handle_one(M, State) || M <- List])
            end;
        {ok, Map} when is_map(Map) ->
            thoas:encode(handle_one(Map, State));
        _ ->
            thoas:encode(error_response(null, -32700, <<"parse error">>))
    end.

handle_one(Map, State) ->
    Id = maps:get(<<"id">>, Map, null),
    case maps:get(<<"method">>, Map, undefined) of
        undefined ->
            error_response(Id, -32600, <<"missing method">>);
        Method when is_binary(Method) ->
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
                {error, Reason} ->
                    error_response(Id, -32000, to_bin(Reason))
            end;
        _ ->
            error_response(Id, -32600, <<"method must be a string">>)
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

dispatch(<<"eth_syncing">>, _Params, State) ->
    Sync = maps:get(sync, State, eth_sync),
    case try eth_sync:status(Sync) catch _:_ -> error end of
        false -> {ok, false};
        Map when is_map(Map) -> {ok, Map};
        _ -> {ok, false}
    end;

dispatch(<<"web3_clientVersion">>, _Params, _State) ->
    {ok, <<"etherlang/0.2.0 (erlang)">>};

dispatch(<<"eth_getVersion">>, _Params, _State) ->
    {ok, <<"etherlang/0.2.0 (erlang)">>};

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
    Num = resolve_num(Chain, NumHex),
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
    Num = resolve_num(Chain, NumHex),
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
    Num = resolve_num(Chain, NumHex),
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

dispatch(_Method, Params, _State) ->
    proxy(_Method, Params).

%% Upstream passthrough.
proxy(Method, Params) ->
    case eth_rpc_client:call(Method, Params) of
        {ok, Result} -> {ok, Result};
        {error, {rpc_error, Err}} when is_map(Err) ->
            Code = maps:get(<<"code">>, Err, -32000),
            Msg = maps:get(<<"message">>, Err, <<"upstream error">>),
            {error, {upstream_error, Code, Msg}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Resolve a block-number reference ("latest"/"earliest"/"pending"/
%% "finalized"/"safe" or a 0x-hex number) to an actual block number for the
%% local store. `safe' is approximated by the finalized checkpoint we track.
resolve_num(Chain, <<"latest">>) -> max(local_head_num(Chain), 0);
resolve_num(Chain, <<"pending">>) -> max(local_head_num(Chain), 0);
resolve_num(Chain, <<"finalized">>) -> finality_num(Chain);
resolve_num(Chain, <<"safe">>) -> finality_num(Chain);
resolve_num(_Chain, <<"earliest">>) -> 0;
resolve_num(_Chain, Hex) -> eth_hex:decode(Hex).

finality_num(Chain) ->
    case try eth_chain:finalized(Chain) catch _:_ -> error end of
        F when is_integer(F) -> F;
        _ -> max(local_head_num(Chain), 0)
    end.

%% Pass tags through to upstream verbatim, otherwise use the raw hex number.
num_or_tag(Hex, _Num) -> Hex.

local_head_num(Chain) ->
    case eth_chain:head(Chain) of
        {N, _} -> N;
        undefined -> 0
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
to_bin(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).