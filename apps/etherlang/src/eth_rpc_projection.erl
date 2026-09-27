%% Projections of what this node stores into the shapes the JSON-RPC
%% specification defines.
%%
%% This module exists because the answer to most of these methods is *not* a
%% computation from nothing -- it is an annotation of something already stored.
%% The chain store keeps the `eth_getBlockByNumber' response verbatim, so a
%% transaction object is already in the specification's shape except for the
%% three fields that are properties of its *position* rather than of the
%% transaction: `blockHash', `blockNumber' and `transactionIndex'. That is the
%% whole of `eth_getTransactionByHash'. Writing it as a re-encoder would mean a
%% second codec to keep in step with the first, and a place for a field to be
%% renamed in one and not the other.
%%
%% The other thing this module is for is saying *no*. Every function here
%% answers only from what the node holds and reports `{error, Reason}' when it
%% holds nothing bearing on the question. It does not fill a gap with a
%% plausible value, and it does not answer from a peer's opinion: the handler
%% proxies in those cases, and a locally-derived answer is always a derivation.
%% `eth_getProof' is the sharpest case -- the specification's `AccountProof' has
%% `additionalProperties: false' and seven required fields, every one of them a
%% fact about a state trie this node must hold, and the default `base_source' is
%% `upstream', where reads come from a peer and there is no local trie to prove
%% against. So the answer there is that it cannot answer, not a proof over a
%% state it does not have. That is `base_source/0' itself applied to the one
%% method whose entire output is a commitment.
%%
%% Field names and required sets are taken from the OpenRPC specification at
%% `src/eth/{block,client,fee_market,state,transaction}.yaml' and
%% `src/schemas/{base-types,state}.yaml' in ethereum/execution-apis. Where the
%% specification does not define a case -- `eth_feeHistory' with a `blockCount' of
%% 0, which it does not mention -- the choice made here is recorded in the
%% comment on the function and pinned by a test, rather than left implicit.
-module(eth_rpc_projection).

-export([ resolve_block_number/2,
          receipt_response/8,
          enrich_logs/6,
          block_receipts/2,
          transaction_at/3,
          transaction_by_hash/2,
          fee_history/4,
          account_proof/3 ]).

%% ---------------------------------------------------------------------------
%% Block number resolution
%% ---------------------------------------------------------------------------
%%
%% `BlockNumberOrTag' is one vocabulary and it must be read one way: `latest',
%% `pending', `finalized' and `safe' resolve against *this* chain's head and
%% finality checkpoint, and a hex string is a height. Three methods take it
%% (`eth_feeHistory's newestBlock, eth_getBlockReceipts's Block, eth_getProof's
%% Block), and three copies of this resolution is three chances for `finalized'
%% to come to mean something different in one of them.
%%
%% `pending' resolves to the head. This node keeps no separate pending block, so
%% `latest' and `pending' are the same height -- a true statement about the node
%% rather than a fudge.
-spec resolve_block_number(atom(), binary() | integer()) -> integer().
resolve_block_number(Chain, <<"latest">>) -> max(head_num(Chain), 0);
resolve_block_number(Chain, <<"pending">>) -> max(head_num(Chain), 0);
resolve_block_number(Chain, <<"finalized">>) -> finality_num(Chain);
resolve_block_number(Chain, <<"safe">>) -> finality_num(Chain);
resolve_block_number(_Chain, <<"earliest">>) -> 0;
resolve_block_number(_Chain, Hex) when is_binary(Hex) -> eth_hex:decode(Hex);
resolve_block_number(_Chain, N) when is_integer(N) -> N.

head_num(Chain) ->
    case eth_chain:head(Chain) of
        {N, _} -> N;
        undefined -> 0
    end.

finality_num(Chain) ->
    case try eth_chain:finalized(Chain) catch _:_ -> error end of
        F when is_integer(F) -> F;
        _ -> max(head_num(Chain), 0)
    end.

%% ---------------------------------------------------------------------------
%% Receipts
%% ---------------------------------------------------------------------------
%%
%% Moved here from eth_rpc_handler unchanged, and now shared by two methods
%% rather than reachable from one. `eth_getTransactionReceipt' and
%% `eth_getBlockReceipts' return the *same* object -- the specification's
%% `ReceiptInfo' -- for one transaction and for a whole block respectively, so
%% they share one projection rather than agreeing by inspection. The existing
%% receipt tests cover the move: a projection that changed shape fails them.
-spec receipt_response(binary(), integer(), binary(), integer(), map(), map(),
                       integer(), integer()) -> map().
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

%% eth_getBlockReceipts: "Returns the receipts of a block by number or hash."
%%
%% Four outcomes, and they are four different things:
%%
%%   {ok, []}   the block is held and has no transactions, so it has no receipts
%%              whatever and the absence of stored receipts is not information.
%%   {ok, Rs}   the block is held and its receipts are stored.
%%   {error, not_found}  the block is not held, or was pruned away.
%%   {error, {pruned_history, Num}}  the block is held but its receipts were
%%              never stored. The specification names this case -- the
%%              `4444 Pruned history unavailable' error on this method -- and it
%%              is not the same as "no such block".
%%
%% The distinction is carried by exactly one check, and it is the one thing worth
%% getting right here. `eth_chain' stores receipts only for blocks it was given
%% receipts for, so a block stored without them is a real block whose receipts
%% are unknown. Collapsing the two would answer `[]' -- "this block has no
%% transactions" -- for a block that had two hundred of them, and a client
%% building a block index from that would silently lose every transaction in it.
-spec block_receipts(atom(), integer()) ->
          {ok, [map()]}
          | {error, not_found}
          | {error, {pruned_history, integer()}}.
block_receipts(Chain, Num) ->
    case try eth_chain:get_by_number(Chain, Num) catch _:_ -> not_found end of
        {ok, Block, _Full} when is_map(Block) ->
            Txs = maps:get(<<"transactions">>, Block, []),
            case try eth_chain:receipts(Chain, Num) catch _:_ -> not_found end of
                {ok, Receipts} when is_list(Receipts) ->
                    {ok, zip_receipts(Block, Num, Txs, Receipts)};
                _ when Txs =:= [] ->
                    {ok, []};
                _ ->
                    {error, {pruned_history, Num}}
            end;
        _ ->
            {error, not_found}
    end.

%% One receipt per transaction, each with the block context the stored receipt
%% does not carry.
%%
%% `gasUsed' is the difference between this receipt's cumulative figure and the
%% previous one's, because that is all a receipt stores. The first transaction's
%% previous is 0 -- nothing precedes it in the block. `eth_rpc_handler' already
%% derives `gasUsed' this way for `eth_getTransactionReceipt', and the two
%% derivations must agree or the same block would report different per-transaction
%% gas depending on which method asked, which is a bug a client would see as an
%% inconsistent chain rather than as two implementations.
zip_receipts(Block, Num, Txs, Receipts) ->
    BlockHash = maps:get(<<"hash">>, Block, undefined),
    Cums = [cum_value(R) || R <- Receipts],
    PrevCums = previous_of(Cums),
    Indexed = lists:zip(lists:zip(Txs, Receipts),
                        lists:zip(lists:seq(0, length(Receipts) - 1),
                                  lists:zip(Cums, PrevCums))),
    [receipt_response(BlockHash, Num, tx_hash(Tx), Idx, Tx, R, Cum, Cum - Prev)
     || {{Tx, R}, {Idx, {Cum, Prev}}} <- Indexed].

%% The cumulative figure *before* each entry: zero for the first, because nothing
%% precedes it in the block, and the previous entry's figure for the rest. The result
%% is the same length as the input, which is what lets the caller zip the two.
%%
%% Two versions of this were wrong, and both crashed or corrupted the ordinary case.
%% `[0 | tl(Cums)]` drops the wrong end of the list, so with figures 1000, 2000, 3000
%% the "previous" values came out 0, 2000, 3000 and every `gasUsed' after the first
%% was 0 -- and `eth_rpc_handler', which computes the same thing correctly for
%% `eth_getTransactionReceipt' by walking the list once, disagreed with it.
%%
%% `[0 | init_safe(Cums)]` fixed that and then raised function_clause on every block
%% with *no* transactions, because `init_safe([])' is `[]' and `[0 | []]' is `[0]' --
%% one element for an empty list. A block with no transactions is the common case, so
%% the common case crashed. A block with no transactions has no receipts to walk.
previous_of([]) -> [];
previous_of([_]) -> [0];
%% `lists:droplast/1' and not `lists:init/1': init was removed in OTP 28, and
%% calling it answers `undef' at runtime rather than at compile time.
previous_of(L) -> [0 | lists:droplast(L)].

cum_value(R) when is_map(R) ->
    to_int(maps:get(<<"cumulative_gas_used">>, R,
                    maps:get(<<"cumulativeGasUsed">>, R, 0)));
cum_value(_) -> 0.

tx_hash(Tx) when is_map(Tx) -> maps:get(<<"hash">>, Tx, null);
tx_hash(_) -> null.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) ->
    try eth_hex:decode(B) catch _:_ -> 0 end;
to_int(_) -> 0.

%% ---------------------------------------------------------------------------
%% Transactions by position
%% ---------------------------------------------------------------------------
%%
%% A stored transaction object is already `TransactionInfo' apart from the three
%% positional fields. `eth_getTransactionByBlockNumberAndIndex' used to return
%% the stored object unannotated, so a client destructuring `blockHash' or
%% `transactionIndex' from it found `undefined' -- and found it consistently,
%% because `eth_getBlockByNumber' with `fullTransactions = false' omits exactly
%% those fields for the same reason. The two were wrong together, which is why no
%% test caught it: a fixture built from the same stored block cannot tell.
-spec transaction_at(atom(), integer(), integer()) ->
          {ok, map()} | {error, not_found} | {error, {pruned_history, integer()}}.
transaction_at(_Chain, _Num, Index) when not is_integer(Index); Index < 0 ->
    %% Not an index at all. Without this the function clause raises, and the
    %% handler's safe-call turns that into -32603 for a request that has a
    %% perfectly good answer: `null', because a block has no transaction at a
    %% negative position. `-1' arrives whenever a client sends a quantity that
    %% decodes to a negative number.
    {error, not_found};
transaction_at(Chain, Num, Index) when is_integer(Index), Index >= 0 ->
    case try eth_chain:get_by_number(Chain, Num) catch _:_ -> not_found end of
        {ok, Block, true} when is_map(Block) ->
            case nth(maps:get(<<"transactions">>, Block, []), Index, 0) of
                {ok, Tx} -> {ok, annotate(Block, Num, Index, Tx)};
                error -> {error, not_found}
            end;
        {ok, _Block, false} ->
            %% Only a block stored with its full transaction list has one to index
            %% into. This is the same `4444' case as the receipts above: the block
            %% is held, the transactions are not.
            {error, {pruned_history, Num}};
        _ ->
            {error, not_found}
    end.

%% eth_getTransactionByHash, via the store's transaction index.
%%
%% `eth_chain' indexes transactions only for blocks stored with their full
%% transaction list -- `index_txs/4' returns early otherwise -- so a miss is
%% genuinely a miss and the handler may proxy.
-spec transaction_by_hash(atom(), binary()) -> {ok, map()} | {error, not_found}.
transaction_by_hash(Chain, TxHash) when is_binary(TxHash) ->
    %% Normalise *before* the index lookup, not only before the scan. The index is a
    %% dets set keyed on the stored object's own `hash' string, so a lookup with the
    %% upper-case spelling of a hash the node holds misses -- and the miss is
    %% indistinguishable from "this node has never seen that transaction", so the
    %% request goes upstream and comes back with somebody else's answer. The first
    %% version normalised only for the in-block scan, where it could never help
    %% because the lookup had already failed.
    Key = norm_hash(TxHash),
    case try eth_chain:tx_block(Chain, Key) catch _:_ -> not_found end of
        {ok, Num} when is_integer(Num) ->
            case try eth_chain:get_by_number(Chain, Num) catch _:_ -> not_found end of
                {ok, Block, true} when is_map(Block) ->
                    case find_tx(maps:get(<<"transactions">>, Block, []), Key, 0) of
                        {ok, Index, Tx} -> {ok, annotate(Block, Num, Index, Tx)};
                        error -> {error, not_found}
                    end;
                _ ->
                    {error, not_found}
            end;
        _ ->
            {error, not_found}
    end.

%% The index is keyed on the stored object's own `hash' value, which is the
%% 0x-prefixed form. A caller may supply the upper-case form, and that is the
%% *same* hash, so a lookup that did not normalise would answer "not found" for a
%% transaction the node holds. Case-normalise and keep the prefix.
norm_hash(H) when is_binary(H) ->
    case H of
        <<"0x", Rest/binary>> -> <<"0x", (string:lowercase(Rest))/binary>>;
        _ -> <<"0x", (string:lowercase(H))/binary>>
    end;
norm_hash(H) when is_integer(H) -> eth_hex:encode_int(H).

find_tx([], _Hash, _Index) -> error;
find_tx([Tx | Rest], Hash, Index) when is_map(Tx) ->
    case maps:get(<<"hash">>, Tx, undefined) of
        Hash -> {ok, Index, Tx};
        _ -> find_tx(Rest, Hash, Index + 1)
    end;
find_tx([_ | Rest], Hash, Index) ->
    find_tx(Rest, Hash, Index + 1).

annotate(Block, Num, Index, Tx) when is_map(Tx) ->
    Tx#{<<"blockHash">> => maps:get(<<"hash">>, Block, undefined),
        <<"blockNumber">> => eth_hex:encode_int(Num),
        <<"transactionIndex">> => eth_hex:encode_int(Index)};
annotate(_Block, _Num, _Index, _Tx) -> null.

nth([], _Index, _N) -> error;
nth([H | _], 0, _N) -> {ok, H};
nth([_ | T], Index, N) when Index > 0 -> nth(T, Index - 1, N + 1).

%% The decrement is the whole function. The first version recursed with the *same*
%% Index and only incremented a counter it never used, so every index except 0 walked
%% off the end of the list and answered "not found" -- for a block this node held,
%% with the transaction in it, at an index that exists. A transaction at index 0 was
%% the only one findable, which is a bug that looks like a truncated block.

%% ---------------------------------------------------------------------------
%% eth_feeHistory
%% ---------------------------------------------------------------------------
%%
%% From `src/eth/fee_market.yaml' in ethereum/execution-apis, *not* from EIP-1559:
%% the EIP specifies the base fee mechanism and never mentions this method, so
%% the OpenRPC file is the only authority for its shape. Four things in it are
%% easy to get wrong and all four are load-bearing:
%%
%%   1. `baseFeePerGas' has one MORE entry than there are blocks: "This includes
%%      the next block after the newest of the returned range, because this value
%%      can be derived from the newest block." That extra value is EIP-1559's
%%      update applied to the newest returned block, which
%%      `eth_fork_schedule:base_fee/3' already implements. Reading one base fee
%%      per block makes the array a block short, and a client using it to price
%%      the *next* block -- which is the entire reason the field is there --
%%      then uses a fee from two blocks ago.
%%
%%   2. `gasUsedRatio' has one entry per block, NOT one more. The two arrays are
%%      deliberately different lengths: the specification's own example is
%%      blockCount 5, six base fees and five ratios.
%%
%%   3. `gasUsedRatio' is a JSON *number*, not a hex string. Every other value in
%%      the result is a quantity, so the obvious encoding is the wrong one.
%%
%%   4. "Zeroes are returned for pre-EIP-1559 blocks" -- a block with no
%%      `baseFeePerGas' contributes 0, not one derived from its parent.
%%
%% `reward' is not in the specification's `required' list and the result is
%% `additionalProperties: false', so omitting it is conformant. It is computed
%% anyway, because a client that asked for percentiles and got no `reward' has
%% been told nothing, and every input is present: a transaction's effective tip
%% follows from its own fee fields and the block's base fee, and the gas it
%% consumed is the difference of consecutive cumulative figures.
-spec fee_history(atom(), integer(), binary() | integer(), [number()]) ->
          {ok, map()} | {error, term()}.
fee_history(Chain, BlockCount, Newest, Percentiles)
  when is_integer(BlockCount), BlockCount > 0, is_list(Percentiles) ->
    case check_percentiles(Percentiles) of
        ok ->
            NewestNum = resolve_block_number(Chain, Newest),
            Head = head_num(Chain),
            case NewestNum > Head orelse NewestNum < 0 of
                true ->
                    {error, {newest_not_held, NewestNum}};
                false ->
                    Oldest = max(0, NewestNum - BlockCount + 1),
                    {ok, history(Chain, Oldest, NewestNum, Percentiles)}
            end;
        {error, _} = E ->
            E
    end;
%% The specification does not define a `blockCount' of 0. It says only that a
%% client "will return less than the requested range if not all blocks are
%% available", which is about a short range, not an empty one -- and `oldestBlock'
%% is a *required* field, for which a zero-block range has no value at all.
%%
%% So this refuses. The alternatives were to report `oldestBlock = newest + 1',
%% which is a convention nothing in the specification states and a client would
%% then use as a height, or to report an empty range under a newest block that
%% was not returned. A refusal is answerable and honest; a convention would be a
%% number this node invented, in a field whose name is a block height.
fee_history(_Chain, 0, _Newest, _Percentiles) ->
    {error, invalid_block_count};
fee_history(_Chain, _BlockCount, _Newest, _Percentiles) ->
    {error, bad_params}.

%% "A monotonically increasing list of percentile values... between 0 and 100."
%% A decreasing list or one outside the range is not a percentile list, and
%% sorting it silently would answer a different question from the one asked.
check_percentiles(Ps) ->
    case lists:all(fun(P) -> is_number(P) andalso P >= 0 andalso P =< 100 end, Ps)
        andalso lists:sort(Ps) =:= Ps of
        true -> ok;
        false -> {error, invalid_percentiles}
    end.

history(Chain, Oldest, Newest, Percentiles) ->
    Blocks = [block_of(Chain, N) || N <- lists:seq(Oldest, Newest)],
    %% The extra base fee is derived from the *newest returned* block, which is the
    %% last one -- not the first. `hd(Blocks)' was the bug, and it only showed when
    %% the range began at a pre-EIP-1559 block: the newest block had a base fee, the
    %% oldest did not, and deriving from the oldest produced a zero for the block
    %% after the head. A range of one block is its own newest, and the two agree --
    %% which is why a single-block request hid this.
    BaseFees = [base_fee_of(B) || B <- Blocks] ++ [next_base_fee(lists:last(Blocks))],
    Result = #{<<"oldestBlock">> => eth_hex:encode_int(Oldest),
               <<"baseFeePerGas">> => [eth_hex:encode_int(F) || F <- BaseFees],
               <<"gasUsedRatio">> => [gas_ratio(B) || B <- Blocks]},
    case Percentiles of
        [] -> Result;
        _ -> Result#{<<"reward">> => [rewards(Chain, B, Percentiles) || B <- Blocks]}
    end.

%% The base fee of the block *after* the newest returned one. EIP-1559's update,
%% which is a pure function of the parent -- and the parent is the newest returned
%% block, which carries its own base fee. The next block may not exist yet, which
%% is precisely why the specification calls this value "derivable" rather than
%% asking for the block.
next_base_fee(#{<<"baseFeePerGas">> := Fee, <<"gasUsed">> := Used,
                <<"gasLimit">> := Limit}) ->
    eth_fork_schedule:base_fee(eth_hex:decode(Used), eth_hex:decode(Limit),
                               eth_hex:decode(Fee));
%% A pre-1559 newest block has no base fee and none to update, so the block after
%% it has none either. Zero, which is what the specification prescribes for
%% pre-EIP-1559 blocks.
next_base_fee(_B) -> 0.

%% "Zeroes are returned for pre-EIP-1559 blocks."
base_fee_of(#{<<"baseFeePerGas">> := Fee}) -> eth_hex:decode(Fee);
base_fee_of(_B) -> 0.

%% "These are calculated as the ratio of gasUsed and gasLimit." A block with no
%% gas limit has no ratio to calculate; zero is both the honest reading of 0/x and
%% what an empty block reports anyway.
gas_ratio(#{<<"gasUsed">> := Used, <<"gasLimit">> := Limit}) ->
    case eth_hex:decode(Limit) of
        0 -> 0.0;
        L -> eth_hex:decode(Used) / L
    end;
gas_ratio(_B) -> 0.0.

block_of(Chain, N) ->
    case try eth_chain:get_by_number(Chain, N) catch _:_ -> not_found end of
        {ok, B, _} when is_map(B) -> B;
        _ -> #{}
    end.

%% Every transaction in a block, with the gas it consumed and the tip it paid.
%% "the transactions will be sorted in ascending order by effective tip per gas
%% and the corresponding effective tip for the percentile will be determined,
%% accounting for gas consumed."
tips_in(Chain, Block) ->
    Num = quantity(maps:get(<<"number">>, Block, <<"0x0">>)),
    Txs = maps:get(<<"transactions">>, Block, []),
    case try eth_chain:receipts(Chain, Num) catch _:_ -> not_found end of
        {ok, Receipts} when is_list(Receipts) ->
            BaseFee = base_fee_of(Block),
            %% Zipped as *pairs* -- transaction with receipt, receipt with its
            %% predecessor -- and not as three independent lists. The three-list
            %% version raised function_clause on the first block with no
            %% transactions, because the "before" list is one longer than the
            %% transaction list there and lists:zip/3 requires equal lengths. A
            %% block with no transactions is the ordinary case, so the ordinary case
            %% crashed.
            Cums = [cum_value(R) || R <- Receipts],
            Prevs = previous_of(Cums),
            Entries = [entry(Tx, R, Cum, Prev, BaseFee)
                       || {{Tx, R}, {Cum, Prev}} <-
                              lists:zip(lists:zip(Txs, Receipts),
                                        lists:zip(Cums, Prevs))],
            [E || E <- Entries, E =/= error];
        _ ->
            []
    end.

entry(Tx, R, Cum, Prev, BaseFee) when is_map(Tx), is_map(R) ->
    case effective_tip(Tx, BaseFee) of
        {ok, Tip} -> {Tip, Cum - Prev};
        error -> error
    end;
entry(_, _, _, _, _) -> error.

%% The tip a proposer actually receives: the priority fee, capped by what is left
%% of maxFeePerGas after the base fee is burned. This is the same definition
%% `eth_block_builder:block_value/1' uses, and it is deliberately the same
%% *formula* reached from the same helper -- see `eth_block_builder:suggested_tip/1',
%% which is where the two are kept together. A second implementation here would
%% be a second answer to "what is this transaction's tip", and a percentile
%% computed from a different tip than the one a proposer would earn is a number
%% that looks right and is wrong by the difference.
effective_tip(Tx, BaseFee) ->
    Prio = quantity(maps:get(<<"maxPriorityFeePerGas">>, Tx, undefined)),
    MaxFee = quantity(maps:get(<<"maxFeePerGas">>, Tx, undefined)),
    GasPrice = quantity(maps:get(<<"gasPrice">>, Tx, undefined)),
    case {Prio, MaxFee} of
        {undefined, _} ->
            %% A legacy transaction pays the whole gasPrice, of which the base fee
            %% is burned.
            case GasPrice of
                undefined -> error;
                _ -> {ok, max(0, GasPrice - BaseFee)}
            end;
        {_, undefined} ->
            {ok, Prio};
        {P, M} when P < M ->
            {ok, P};
        {_, M} ->
            {ok, max(0, M - BaseFee)}
    end.

quantity(undefined) -> undefined;
quantity(V) when is_integer(V), V >= 0 -> V;
quantity(V) when is_binary(V) ->
    try eth_hex:decode(V) catch _:_ -> undefined end;
quantity(_) -> undefined.

rewards(_Chain, _Block, []) ->
    [];
rewards(Chain, Block, Percentiles) ->
    Sorted = lists:sort(fun(A, B) -> element(1, A) =< element(1, B) end,
                        tips_in(Chain, Block)),
    TotalGas = lists:sum([G || {_Tip, G} <- Sorted]),
    [percentile(Sorted, TotalGas, P) || P <- Percentiles].

%% "All zeroes are returned if the block is empty." A block with no priceable
%% transaction has no distribution to sample, and a percentile of nothing is zero
%% -- the specification says so, and any other value would be invented. This is
%% also what keeps a block whose receipts this node does not hold from reporting a
%% row of non-zero numbers it derived from no data.
%%
%% The zero is `eth_hex:encode_int(0)' and not the integer 0, because every other
%% entry in a reward row is a `uint' and a bare 0 among three hex strings is a shape
%% the client has to special-case. The first version returned the integer, so an
%% empty block produced `[0, 0, 0]' where a populated one produced
%% `["0x3b9aca00", ...]'.
percentile([], _TotalGas, _P) ->
    eth_hex:encode_int(0);
percentile(Sorted, TotalGas, P) ->
    walk(Sorted, 0, TotalGas * P / 100).

walk([], _Cum, _Threshold) ->
    eth_hex:encode_int(0);
walk([{Tip, Gas} | Rest], Cum, Threshold) ->
    case Cum + Gas >= Threshold of
        true -> eth_hex:encode_int(Tip);
        false -> walk(Rest, Cum + Gas, Threshold)
    end.

%% ---------------------------------------------------------------------------
%% eth_getProof
%% ---------------------------------------------------------------------------
%%
%% The specification's `AccountProof' has `additionalProperties: false' and
%% requires all seven of `address, accountProof, balance, codeHash, nonce,
%% storageHash, storageProof'. Every one is a fact about a state trie this node
%% must hold, and the default `base_source' is `upstream', where there is no local
%% trie. So this answers from the local trie only, and says why otherwise.
%%
%% `storageHash' comes from `eth_mpt:storage_root/1', which is the same function
%% the state root is rebuilt with. Recomputing it here would be a second answer
%% to "what is this account's storage root", and a storage proof checked against
%% a root the state does not commit to is a proof of nothing.
-spec account_proof(binary(), [binary()], binary() | integer()) ->
          {ok, map()} | {error, term()}.
account_proof(Address, Slots, _Block) when is_binary(Address), is_list(Slots) ->
    case eth_state:base_source() of
        mpt -> local_proof(Address, Slots);
        Other -> {error, {state_not_local, Other}}
    end;
account_proof(_Address, _Slots, _Block) ->
    {error, bad_params}.

local_proof(Address, Slots) ->
    Addr = address_bytes(Address),
    Account = try eth_mpt:get_account(Addr) catch _:_ -> undefined end,
    case {Account, storage_root_of(Addr)} of
        {#{balance := Balance, nonce := Nonce, codeHash := CodeHash}, StorageRoot}
          when is_binary(StorageRoot) ->
            State = eth_state:new({0, <<>>}, #{}),
            {ok, #{<<"address">> => eth_hex:encode_bytes(Addr),
                   <<"balance">> => eth_hex:encode_int(to_int(Balance)),
                   <<"nonce">> => eth_hex:encode_int(to_int(Nonce)),
                   <<"codeHash">> => hex32(CodeHash),
                   <<"storageHash">> => hex32(StorageRoot),
                   <<"accountProof">> => [hex(N) || N <- proof_nodes(Addr)],
                   <<"storageProof">> => [storage_proof(State, Addr, Slot)
                                          || Slot <- Slots]}};
        {undefined, _} ->
            %% The local trie does not hold this account. The specification's
            %% result here is an object and not `null' -- there is no `oneOf' with
            %% `notFound' on this method -- so there is no short answer available
            %% and refusing is the only honest one. The handler proxies.
            {error, account_not_local};
        _ ->
            {error, account_not_local}
    end.

storage_root_of(Addr) ->
    case try eth_mpt:storage_root(Addr) catch _:_ -> {error, unavailable} end of
        {ok, Root} -> Root;
        _ -> undefined
    end.

proof_nodes(Addr) ->
    case try eth_mpt:prove_account(Addr) catch _:_ -> {error, not_found} end of
        {ok, Nodes} when is_list(Nodes) -> Nodes;
        _ -> []
    end.

%% The value is read through `eth_state:storage/3' rather than from the trie
%% directly, because `eth_state' owns the one definition of what a storage slot
%% key is (`slot_key/1') and the one decision of where a read comes from. Reading
%% the trie here would be a second path to the same fact, and a slot written
%% through one spelling and read through another is a slot that reads as zero.
storage_proof(State, Addr, Slot) ->
    Word = slot_word(Slot),
    Nodes = case try eth_mpt:prove_storage(Addr, word_int(Word))
             catch _:_ -> {error, not_found} end of
               {ok, N} when is_list(N) -> [hex(X) || X <- N];
               _ -> []
           end,
    %% eth_state:storage/3 takes a slot in any spelling and normalises it, so the
    %% key reported to the client and the key read are the same one.
    Value = case (try eth_state:storage(State, Addr, Word) catch _:_ -> 0 end) of
                0 -> eth_hex:encode_int(0);
                V when is_integer(V) -> eth_hex:encode_int(V);
                V2 when is_binary(V2) -> eth_hex:encode_int(to_int(V2));
                _ -> eth_hex:encode_int(0)
            end,
    #{<<"key">> => eth_hex:encode_bytes(Word),
      <<"value">> => Value,
      <<"proof">> => Nodes}.

%% A storage key is `bytesMax32' in the specification: between 0 and 32 bytes, not
%% necessarily 32. It is *left*-padded to a full 32-byte word before hashing,
%% because the storage trie's key is keccak256 of the slot as a big-endian word
%% -- the same rule and for the same reason as `eth_state:slot_key/1', which
%% left-pads rather than right-padding. A short key hashed as a suffix is a proof
%% of a different slot, and the client cannot tell: it asked about slot 0x01 and
%% received a well-formed proof.
slot_word(S) when is_integer(S) -> <<S:256>>;
slot_word(S) when is_binary(S) -> pad_left(slot_nibbles(S));
slot_word(_) -> <<0:256>>.

all_hex(<<>>) -> true;
all_hex(<<C, Rest/binary>>) when C >= $0, C =< $9 -> all_hex(Rest);
all_hex(<<C, Rest/binary>>) when C >= $a, C =< $f -> all_hex(Rest);
all_hex(<<C, Rest/binary>>) when C >= $A, C =< $F -> all_hex(Rest);
all_hex(_) -> false.

%% The nibbles of a storage key, tolerating an odd count.
%%
%% `eth_hex:decode_bytes/1' is deliberately strict -- DATA is a byte string, so an
%% odd number of nibbles is malformed and saying so is right for a hash. A storage
%% key is not that: the specification types it `bytesMax32', clients send `"0x1"',
%% and every node accepts it. Read strictly, `"0x1"' decodes to nothing at all, the
%% key becomes 32 zero bytes, and the client receives a well-formed proof of slot
%% zero for a question about slot one -- the same silent wrong answer as the
%% padding direction, one step earlier.
%%
%% A left zero nibble is the standard reading: `"0x1"' and `"0x01"' are the same
%% slot, and both are slot 1.
slot_nibbles(S) when is_binary(S) ->
    Nibbles = case S of
                  <<"0x", R/binary>> -> R;
                  <<"0X", R/binary>> -> R;
                  _ -> S
              end,
    case all_hex(Nibbles) of
        false -> <<>>;
        true when byte_size(Nibbles) rem 2 =:= 0 -> binary:decode_hex(Nibbles);
        true -> binary:decode_hex(<<"0", Nibbles/binary>>)
    end;
slot_nibbles(_) -> <<>>.

pad_left(Bytes) when byte_size(Bytes) =:= 32 -> Bytes;
pad_left(Bytes) when byte_size(Bytes) < 32 ->
    <<0:((32 - byte_size(Bytes)) * 8), Bytes/binary>>;
pad_left(Bytes) -> binary:part(Bytes, byte_size(Bytes) - 32, 32).

%% eth_mpt:prove_storage/2 takes the slot as an integer, and its integer clause is
%% the correct big-endian one. Passing the 32-byte word through the integer path
%% keeps both spellings of the same slot on the same path.
word_int(Word) -> binary:decode_unsigned(Word).

address_bytes(Address) ->
    case eth_hex:decode_bytes(Address) of
        {ok, Bytes} when byte_size(Bytes) =:= 20 -> Bytes;
        _ -> <<0:160>>
    end.

%% codeHash and storageHash are `hash32': exactly 32 bytes, always 64 nibbles. A
%% short value zero-padded would be a *different* hash, and a long one is not a
%% hash32 at all. An absent value is reported as the zero hash, which for the
%% empty-code account is what it is.
hex32(<<>>) -> eth_hex:encode_bytes(<<0:256>>);
hex32(B) when is_binary(B), byte_size(B) =:= 32 -> eth_hex:encode_bytes(B);
hex32(B) when is_binary(B) -> eth_hex:encode_bytes(pad_left(B));
hex32(_) -> eth_hex:encode_bytes(<<0:256>>).

hex(B) when is_binary(B) -> eth_hex:encode_bytes(B);
hex(_) -> eth_hex:encode_bytes(<<0:256>>).
