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
                    eth_peer:broadcast([hex_to_bin(Hash)]),
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

dispatch(_Method, Params, _State) ->
    proxy(_Method, Params).

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
            {error, {upstream_error, Code, Msg}};
        {error, Reason} ->
            {error, Reason}
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
            {ok, receipt_response(BlockHash, Num, TxHash, Idx, Tx, R,
                                  Cum, TxGas)};
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

receipt_response(BlockHash, Num, TxHash, Idx, Tx, R, Cum, TxGas) ->
    Logs = enrich_logs(maps:get(<<"logs">>, R, []), BlockHash, Num, TxHash, Idx, 0),
    #{<<"transactionHash">> => TxHash,
      <<"transactionIndex">> => eth_hex:encode_int(Idx),
      <<"blockHash">> => BlockHash,
      <<"blockNumber">> => eth_hex:encode_int(Num),
      <<"from">> => maps:get(<<"from">>, Tx, null),
      <<"to">> => maps:get(<<"to">>, Tx, null),
      <<"cumulativeGasUsed">> => eth_hex:encode_int(Cum),
      <<"gasUsed">> => eth_hex:encode_int(TxGas),
      <<"contractAddress">> => maps:get(<<"contractAddress">>, R, null),
      <<"logs">> => Logs,
      <<"logsBloom">> => maps:get(<<"logs_bloom">>, R, maps:get(<<"logsBloom">>, R, <<"0x">>)),
      <<"status">> => maps:get(<<"status">>, R, <<"0x1">>),
      <<"type">> => maps:get(<<"type">>, R, <<"0x0">>)}.

enrich_logs([], _, _, _, _, _) -> [];
enrich_logs([L | Rest], BlockHash, Num, TxHash, TxIdx, LogIdx) ->
    [L#{<<"blockHash">> => BlockHash,
        <<"blockNumber">> => eth_hex:encode_int(Num),
        <<"transactionHash">> => TxHash,
        <<"transactionIndex">> => eth_hex:encode_int(TxIdx),
        <<"logIndex">> => eth_hex:encode_int(LogIdx),
        <<"removed">> => false}
     | enrich_logs(Rest, BlockHash, Num, TxHash, TxIdx, LogIdx + 1)].

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

log_range(Chain, Filter) ->
    HeadN = local_head_num(Chain),
    From = case maps:get(<<"fromBlock">>, Filter, <<"latest">>) of
               <<"earliest">> -> 0;
               B when is_binary(B) -> log_num(Chain, B)
           end,
    To = case maps:get(<<"toBlock">>, Filter, <<"latest">>) of
             <<"earliest">> -> 0;
             B2 when is_binary(B2) -> log_num(Chain, B2)
         end,
    {max(From, 0), min(To, HeadN)}.

log_num(Chain, <<"latest">>) -> max(local_head_num(Chain), 0);
log_num(Chain, <<"pending">>) -> max(local_head_num(Chain), 0);
log_num(Chain, <<"finalized">>) -> finality_num(Chain);
log_num(Chain, <<"safe">>) -> finality_num(Chain);
log_num(_Chain, <<"earliest">>) -> 0;
log_num(_Chain, Hex) -> eth_hex:decode(Hex).

log_addrs(undefined) -> any;
log_addrs(A) when is_binary(A) -> [norm_hex(A)];
log_addrs(L) when is_list(L) -> [norm_hex(A) || A <- L].

block_logs(Chain, N, Addrs, Topics) ->
    case (try eth_chain:get_by_number(Chain, N) catch _:_ -> not_found end) of
        {ok, Block, true} ->
            case (try eth_chain:receipts(Chain, N) catch _:_ -> not_found end) of
                {ok, Receipts} ->
                    BlockHash = maps:get(<<"hash">>, Block, undefined),
                    Txs = maps:get(<<"transactions">>, Block, []),
                    lists:append(
                      [receipt_logs(BlockHash, N, Tx, R, Idx, Addrs, Topics) ||
                          {{Tx, R}, Idx} <- lists:zip(lists:zip(Txs, Receipts),
                                                      lists:seq(0, length(Receipts) - 1))]);
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
    Logs = enrich_logs(maps:get(<<"logs">>, R, []), BlockHash, N, TxHash, Idx, 0),
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

hex_to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
hex_to_bin(B) when is_binary(B) -> binary:decode_hex(B).

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