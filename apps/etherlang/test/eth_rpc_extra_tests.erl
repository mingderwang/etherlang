%% Tests for the eight JSON-RPC methods this node answers from its own state
%% instead of proxying.
%%
%% Two things shape what is asserted here.
%%
%% First, several of these were not so much missing as unexamined: a catch-all
%% clause proxied every unknown method, so `eth_getBlockReceipts' and friends
%% answered -- with another node's answer. So the tests below are largely about
%% what a *local* answer is derived from, because a local answer that is a guess
%% would be worse than the proxy it replaced.
%%
%% `eth_feeHistory` gets the most attention. Its result carries one more base fee
%% than it has blocks, a `gasUsedRatio' array a different length again, and a
%% ratio that is a JSON number while everything around it is a quantity. Each of
%% those is a plausible mistake, none of them raises, and a client pricing the
%% next block from a base fee two blocks old is not wrong by a rounding.
%%
%% Second, the proofs are *verified* rather than compared. `eth_getProof's whole
%% output is a claim about a state root, so a test that checked the shape of the
%% claim without checking the claim would be testing the shape. `eth_trie`'s own
%% verifier does the checking here, against the root the trie actually holds.
-module(eth_rpc_extra_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ADDR_A, <<16#aa:160>>).
-define(ADDR_HEX, <<"0x00000000000000000000000000000000000000aa">>).
-define(ONE_GWEI, 1000000000).

%% ===========================================================================
%% eth_feeHistory -- the array lengths, and the two that differ
%% ===========================================================================

%% One more base fee than there are blocks: "This includes the next block after the
%% newest of the returned range, because this value can be derived from the newest
%% block." A client prices the *next* block with it, so reading one fee per block
%% makes it use a fee from two blocks ago.
base_fee_per_gas_has_one_more_entry_than_there_are_blocks_test() ->
    with_chain(fun(Chain, Blocks) ->
                   Num = length(Blocks),
                   {ok, R} = eth_rpc_projection:fee_history(Chain, Num,
                                                            <<"latest">>, []),
                   ?assertEqual(Num + 1,
                                length(maps:get(<<"baseFeePerGas">>, R)))
               end).

%% ...and the extra entry is the *next* block's fee, derived from the newest
%% returned block rather than repeated from it. EIP-1559's update is
%% `eth_fork_schedule:base_fee/3', so the expected figure is computable rather
%% than asserted by hand.
the_extra_base_fee_is_the_next_blocks_and_is_not_the_newest_repeated_test() ->
    with_chain(fun(Chain, Blocks) ->
                   Newest = lists:last(Blocks),
                   ?assert(maps:is_key(<<"baseFeePerGas">>, Newest)),
                   {ok, R} = eth_rpc_projection:fee_history(Chain, 2,
                                                            <<"latest">>, []),
                   BaseFees = maps:get(<<"baseFeePerGas">>, R),
                   Expected = eth_fork_schedule:base_fee(gas_of(Newest, <<"gasUsed">>),
                                                          gas_of(Newest, <<"gasLimit">>),
                                                          gas_of(Newest, <<"baseFeePerGas">>)),
                   ?assertEqual(eth_hex:encode_int(Expected), lists:last(BaseFees)),
                   ?assertNotEqual(eth_hex:encode_int(gas_of(Newest, <<"baseFeePerGas">>)),
                                   lists:last(BaseFees))
               end).

%% `gasUsedRatio' has one entry per block -- NOT one more. The two arrays are
%% deliberately different lengths, and this is the easiest thing in the method to
%% get wrong because every other array in the result is either N or N+1 and the
%% base fee array pulls the intuition the wrong way.
gas_used_ratio_has_one_entry_per_block_and_not_one_more_test() ->
    with_chain(fun(Chain, Blocks) ->
                   Num = length(Blocks),
                   {ok, R} = eth_rpc_projection:fee_history(Chain, Num,
                                                            <<"latest">>, []),
                   ?assertEqual(Num, length(maps:get(<<"gasUsedRatio">>, R))),
                   ?assertEqual(Num + 1, length(maps:get(<<"baseFeePerGas">>, R)))
               end).

%% "These are calculated as the ratio of gasUsed and gasLimit" -- and it is a
%% JSON *number*, not a hex string, unlike every other value in the result.
gas_used_ratio_is_a_number_and_not_a_hex_string_test() ->
    with_chain(fun(Chain, Blocks) ->
                   %% `latest' is the head, so this range is the *last* block --
                   %% the first version compared the returned ratio against the
                   %% first block, which is a different block with a different gas
                   %% limit, and so disagreed by construction.
                   Block = lists:last(Blocks),
                   Used = gas_of(Block, <<"gasUsed">>),
                   Limit = gas_of(Block, <<"gasLimit">>),
                   ?assert(Limit > 0),
                   {ok, R} = eth_rpc_projection:fee_history(Chain, 1,
                                                            <<"latest">>, []),
                   [Ratio] = maps:get(<<"gasUsedRatio">>, R),
                   ?assert(is_number(Ratio)),
                   ?assertNot(is_binary(Ratio)),
                   ?assert(abs(Ratio - (Used / Limit)) < 1.0e-12)
               end).

%% "Zeroes are returned for pre-EIP-1559 blocks." A block with no base fee field
%% contributes zero, not a figure derived from its parent.
a_pre_eip_1559_block_reports_a_zero_base_fee_test() ->
    with_chain(fun(Chain, Blocks) ->
                   %% Block 1 of the fixture has no baseFeePerGas.
                   ?assertNot(maps:is_key(<<"baseFeePerGas">>, lists:nth(2, Blocks))),
                   {ok, R} = eth_rpc_projection:fee_history(Chain, 2,
                                                            <<"latest">>, []),
                   %% Two blocks returned, three base fees: the pre-1559 block
                   %% contributes a zero, the post-1559 one its own fee, and the
                   %% third is the head's derived successor.
                   [Zero, _Next, _Derived] = maps:get(<<"baseFeePerGas">>, R),
                   ?assertEqual(<<"0x0">>, Zero),
                   ?assertNotEqual(<<"0x0">>, _Next),
                   ?assertNotEqual(<<"0x0">>, _Derived)
               end).

oldest_block_is_the_lowest_number_returned_test() ->
    with_chain(fun(Chain, _Blocks) ->
                   {ok, R} = eth_rpc_projection:fee_history(Chain, 2,
                                                            <<"latest">>, []),
                   ?assertEqual(<<"0x1">>, maps:get(<<"oldestBlock">>, R))
               end).

%% A request wider than the chain returns what is held -- not an error, and not a
%% range padded out with invented heights.
a_request_wider_than_the_chain_is_trimmed_to_what_is_held_test() ->
    with_chain(fun(Chain, Blocks) ->
                   {ok, R} = eth_rpc_projection:fee_history(Chain, 1000,
                                                            <<"latest">>, []),
                   ?assertEqual(eth_hex:encode_int(0),
                                maps:get(<<"oldestBlock">>, R)),
                   ?assertEqual(length(Blocks) + 1,
                                length(maps:get(<<"baseFeePerGas">>, R)))
               end).

%% A `newestBlock' past the head is not a result and not a guess. Another node
%% holds the block, so the handler asks one.
a_newest_block_past_the_head_is_reported_rather_than_answered_test() ->
    with_chain(fun(Chain, _Blocks) ->
                   ?assertEqual({error, {newest_not_held, 9999}},
                                eth_rpc_projection:fee_history(Chain, 1,
                                                               <<"0x270f">>, []))
               end).

%% The specification does not define a `blockCount' of 0, and `oldestBlock' is
%% required, so a zero-block range has no value for it. Refused rather than
%% invented: the alternative, `oldestBlock = newest + 1', is a convention nothing
%% states and a client would then use as a block height.
a_block_count_of_zero_is_refused_rather_than_answered_with_an_invented_height_test() ->
    with_chain(fun(Chain, _Blocks) ->
                   ?assertEqual({error, invalid_block_count},
                                eth_rpc_projection:fee_history(Chain, 0,
                                                               <<"latest">>, []))
               end).

%% "A monotonically increasing list of percentile values ... between 0 and 100."
%% Sorting a decreasing list silently would answer a different question from the
%% one asked.
a_decreasing_percentile_list_is_refused_test() ->
    with_chain(fun(Chain, _Blocks) ->
                   ?assertEqual({error, invalid_percentiles},
                                eth_rpc_projection:fee_history(Chain, 1,
                                                               <<"latest">>, [50, 20]))
               end).

a_percentile_outside_zero_to_one_hundred_is_refused_test() ->
    with_chain(fun(Chain, _Blocks) ->
                   %% 101 is above the range and -1 is below it; both are refused
                   %% for the same reason and neither is a percentile.
                   ?assertEqual({error, invalid_percentiles},
                                eth_rpc_projection:fee_history(Chain, 1,
                                                               <<"latest">>, [101])),
                   ?assertEqual({error, invalid_percentiles},
                                eth_rpc_projection:fee_history(Chain, 1,
                                                               <<"latest">>, [-1]))
               end).

%% `reward' is absent when no percentiles were asked for. The result is
%% `additionalProperties: false', so an array of empty rows is a deviation of the
%% same kind as a missing required field.
no_reward_key_when_no_percentiles_were_asked_for_test() ->
    with_chain(fun(Chain, _Blocks) ->
                   {ok, R} = eth_rpc_projection:fee_history(Chain, 1,
                                                            <<"latest">>, []),
                   ?assertNot(maps:is_key(<<"reward">>, R))
               end).

the_reward_array_is_one_row_per_block_with_one_entry_per_percentile_test() ->
    with_tip_chain(fun(Chain) ->
                       %% Block 1, the one this fixture gives transactions *and*
                       %% stored receipts. `latest' is the head, and the head has
                       %% neither -- so asking for the head asks about an empty
                       %% block, which the specification says answers zero, and it
                       %% did, for the wrong reason.
                       {ok, R} = eth_rpc_projection:fee_history(Chain, 1,
                                                                <<"0x1">>,
                                                                [10, 50, 90]),
                       [Row] = maps:get(<<"reward">>, R),
                       ?assertEqual(3, length(Row))
                   end).

%% "the transactions will be sorted in ascending order by effective tip per gas
%% and the corresponding effective tip for the percentile will be determined,
%% accounting for gas consumed."
%%
%% Three transactions at 21000 gas each, with tips of 1, 3 and 4 gwei, so the
%% cumulative gas crosses 0%, 50% and 100% at the first, second and third
%% respectively. A walk without the gas weighting, or one computed from the raw
%% gasPrice rather than the tip after the burn, would still produce three numbers
%% here -- and they would not be these.
the_reward_is_the_tip_of_the_transaction_at_that_gas_percentile_test() ->
    with_tip_chain(fun(Chain) ->
                       {ok, R} = eth_rpc_projection:fee_history(Chain, 1,
                                                                <<"0x1">>,
                                                                [0, 50, 100]),
                       [Row] = maps:get(<<"reward">>, R),
                       ?assertEqual([<<"0x3b9aca00">>,      %% 1 gwei
                                     <<"0xb2d05e00">>,      %% 3 gwei
                                     <<"0xee6b2800">>],     %% 4 gwei
                                    Row)
                   end).

%% A legacy transaction pays the whole gasPrice, of which the base fee is burned,
%% so its tip is the difference. Reading gasPrice as the tip over-reports every
%% legacy transaction's contribution.
a_legacy_transactions_tip_excludes_the_burn_test() ->
    with_tip_chain(fun(Chain) ->
                       {ok, R} = eth_rpc_projection:fee_history(Chain, 1,
                                                                <<"0x1">>, [100]),
                       [Row] = maps:get(<<"reward">>, R),
                       %% 5 gwei price less the 1 gwei burn.
                       ?assertEqual([<<"0xee6b2800">>], Row)
                   end).

%% "All zeroes are returned if the block is empty." A block with no transactions has
%% no distribution to sample, and any other value would be invented.
an_empty_block_reports_zero_for_every_percentile_test() ->
    with_tip_chain(fun(Chain) ->
                       {ok, R} = eth_rpc_projection:fee_history(Chain, 1,
                                                                <<"0x0">>,
                                                                [1, 50, 99]),
                       [Row] = maps:get(<<"reward">>, R),
                       ?assertEqual([<<"0x0">>, <<"0x0">>, <<"0x0">>], Row)
                   end).

%% A block whose receipts this node does not hold is not the same as an empty
%% block. Its transactions have no gas figures to weight them by, so the row is
%% zero rather than derived from nothing.
a_block_whose_receipts_are_not_stored_reports_zero_rewards_test() ->
    with_receipt_chain(fun(Chain, Blocks) ->
                           %% Block 2 has three transactions and no stored receipts,
                           %% so there are no gas figures to weight a distribution by.
                           Block = lists:nth(3, Blocks),
                           ?assertEqual(3, length(maps:get(<<"transactions">>, Block))),
                           {ok, R} = eth_rpc_projection:fee_history(Chain, 1,
                                                                    <<"0x2">>, [100]),
                           [Row] = maps:get(<<"reward">>, R),
                           ?assertEqual([<<"0x0">>], Row),
                           %% And the *base fee* is still reported for it, because that
                           %% comes from the header rather than from receipts.
                           [_, Fee] = maps:get(<<"baseFeePerGas">>, R),
                           ?assertNotEqual(<<"0x0">>, Fee),
                           _ = Blocks
                       end).

%% ===========================================================================
%% eth_getBlockReceipts
%% ===========================================================================

block_receipts_are_returned_in_order_with_their_block_context_test() ->
    with_receipt_chain(fun(Chain, _Blocks) ->
                           {ok, Rs} = eth_rpc_projection:block_receipts(Chain, 1),
                           ?assertEqual(3, length(Rs)),
                           ?assertEqual([<<"0x0">>, <<"0x1">>, <<"0x2">>],
                                        [maps:get(<<"transactionIndex">>, R)
                                         || R <- Rs]),
                           [R0 | _] = Rs,
                           ?assertEqual(<<"0x1">>, maps:get(<<"blockNumber">>, R0)),
                           %% cumulativeGasUsed is what the receipt stores; gasUsed
                           %% is this transaction's share of it, which the first
                           %% version of this test also expected to be cumulative.
                           ?assertEqual(eth_hex:encode_int(1000),
                                        maps:get(<<"cumulativeGasUsed">>, R0)),
                           ?assertEqual(eth_hex:encode_int(1000),
                                        maps:get(<<"gasUsed">>, R0))
                       end).

%% `gasUsed' is the difference between this receipt's cumulative figure and the
%% previous one's, because that is all a receipt stores -- and the two methods that
%% read receipts must agree on it, or the same block reports different
%% per-transaction gas depending on which was asked.
per_transaction_gas_is_the_difference_of_consecutive_cumulative_figures_test() ->
    with_receipt_chain(fun(Chain, _Blocks) ->
                           {ok, Rs} = eth_rpc_projection:block_receipts(Chain, 1),
                           Cum = [eth_hex:decode(maps:get(<<"cumulativeGasUsed">>, R))
                                  || R <- Rs],
                           Used = [eth_hex:decode(maps:get(<<"gasUsed">>, R))
                                   || R <- Rs],
                           ?assertEqual([1000, 2000, 3000], Cum),
                           %% Each transaction's share is 1000, and the three share
                           %% the last receipt's cumulative figure -- so the list of
                           %% `gasUsed' is *not* the list of cumulative figures, which
                           %% is what a test comparing the two asserted.
                           ?assertEqual([1000, 1000, 1000], Used),
                           ?assertEqual(lists:last(Cum), lists:sum(Used))
                   end).

%% A block with no transactions has no receipts whatever, so the absence of stored
%% receipts is not information about it. The answer is an empty array -- not
%% `null', which the specification reserves for "not found", and not 4444.
a_block_with_no_transactions_has_an_empty_receipt_list_test() ->
    with_receipt_chain(fun(Chain, Blocks) ->
                           ?assertEqual([], maps:get(<<"transactions">>, hd(Blocks))),
                           ?assertEqual({ok, []},
                                        eth_rpc_projection:block_receipts(Chain, 0))
                       end).

%% The one distinction this method exists to get right. A block stored *without*
%% its receipts is a real block whose receipts are unknown. Answering `[]' -- "this
%% block has no transactions" -- for a block with three of them would be invisible
%% to a client indexing the chain, and would drop every transaction in it.
a_block_whose_receipts_were_never_stored_reports_pruned_history_not_an_empty_list_test() ->
    with_receipt_chain(fun(Chain, Blocks) ->
                           Block = lists:nth(3, Blocks),
                           ?assertEqual(3,
                                        length(maps:get(<<"transactions">>, Block))),
                           ?assertEqual({error, {pruned_history, 2}},
                                        eth_rpc_projection:block_receipts(Chain, 2))
                       end).

a_block_the_node_does_not_hold_is_not_found_test() ->
    with_receipt_chain(fun(Chain, _Blocks) ->
                           ?assertEqual({error, not_found},
                                        eth_rpc_projection:block_receipts(Chain, 99))
                       end).

%% 4444 is the code the specification names for this case on this method. Not
%% -32000, and not `null'.
over_the_wire_a_block_without_receipts_is_4444_test() ->
    with_receipt_chain_http(fun(Port) ->
                                {ok, Body} = rpc(Port, <<"eth_getBlockReceipts">>,
                                                 [<<"0x2">>]),
                                ?assertEqual(4444,
                                             maps:get(<<"code">>,
                                                      maps:get(<<"error">>, Body)))
                            end).

over_the_wire_a_block_with_no_transactions_is_an_empty_array_test() ->
    with_receipt_chain_http(fun(Port) ->
                                {ok, #{<<"result">> := []}} =
                                    rpc(Port, <<"eth_getBlockReceipts">>,
                                        [<<"0x0">>])
                            end).

%% A 32-byte block parameter is a hash, not a height. Resolving it as a number
%% would serve some other block's receipts, because `eth_hex:decode/1` on a hash
%% yields an arbitrary 256-bit integer.
a_block_hash_parameter_is_routed_by_hash_and_not_decoded_as_a_height_test() ->
    with_receipt_chain_http(fun(Port) ->
                                {ok, #{<<"result">> := #{<<"hash">> := Hash}}} =
                                    rpc(Port, <<"eth_getBlockByNumber">>,
                                        [<<"0x1">>, false]),
                                ?assertEqual(66, byte_size(Hash)),
                                {ok, Body} = rpc(Port, <<"eth_getBlockReceipts">>,
                                                 [Hash]),
                                ?assertEqual(3, length(maps:get(<<"result">>, Body)))
                            end).

%% ===========================================================================
%% eth_getTransactionByHash, and the positional fields
%% ===========================================================================

%% A stored transaction object is already the specification's `TransactionInfo'
%% apart from three fields that are properties of its *position*. Those three are
%% what this method adds, and what the method this one shares a projection with was
%% not adding.
a_stored_transaction_gains_the_three_positional_fields_it_does_not_carry_test() ->
    with_receipt_chain(fun(Chain, Blocks) ->
                           Block = lists:nth(2, Blocks),
                           [Tx | _] = maps:get(<<"transactions">>, Block),
                           H = maps:get(<<"hash">>, Tx),
                           %% What is stored does not have them -- which is exactly
                           %% why `eth_getBlockByNumber' with fullTransactions =
                           %% false omits them too.
                           [?assertNot(maps:is_key(K, Tx))
                            || K <- [<<"blockHash">>, <<"blockNumber">>,
                                     <<"transactionIndex">>]],
                           {ok, Found} = eth_rpc_projection:transaction_by_hash(Chain, H),
                           ?assertEqual(H, maps:get(<<"hash">>, Found)),
                           ?assertEqual(<<"0x1">>, maps:get(<<"blockNumber">>, Found)),
                           ?assertEqual(<<"0x0">>,
                                        maps:get(<<"transactionIndex">>, Found)),
                           ?assertEqual(maps:get(<<"hash">>, Block),
                                        maps:get(<<"blockHash">>, Found))
                       end).

%% A client may send the upper-case spelling of the same hash. That is the same
%% transaction, and a lookup that did not normalise would report "not found" for
%% something the node holds -- which sends the request upstream and answers with
%% whatever the peer says instead.
an_upper_case_hash_finds_the_transaction_the_lower_case_spelling_stored_test() ->
    with_receipt_chain(fun(Chain, Blocks) ->
                           [Tx | _] = maps:get(<<"transactions">>, lists:nth(2, Blocks)),
                           H = maps:get(<<"hash">>, Tx),
                           Upper = upper(H),
                           ?assertNotEqual(H, Upper),
                           ?assertMatch({ok, _},
                                        eth_rpc_projection:transaction_by_hash(
                                          Chain, Upper))
                       end).

a_transaction_this_node_does_not_hold_is_not_found_test() ->
    with_receipt_chain(fun(Chain, _Blocks) ->
                           ?assertEqual({error, not_found},
                                        eth_rpc_projection:transaction_by_hash(
                                          Chain, hex0(999)))
                       end).

%% A block stored without its transaction list has no transactions to index, and
%% `eth_chain' does not index it -- so the hash is not answerable from it and 4444
%% is the right code rather than a `null' that reads as "no such transaction".
a_stored_full_block_can_be_indexed_by_transaction_index_test() ->
    with_receipt_chain(fun(Chain, Blocks) ->
                           %% Blocks 1 and 2 are the ones stored with their
                           %% transaction lists, so a transaction is addressable by
                           %% its position in them.
                           WithTxs = [B || B <- Blocks,
                                           maps:get(<<"transactions">>, B) =/= []],
                           ?assertEqual(2, length(WithTxs)),
                           {ok, Tx} = eth_rpc_projection:transaction_at(Chain, 1, 2),
                           ?assertEqual(<<"0x2">>, maps:get(<<"transactionIndex">>, Tx)),
                           ?assertEqual(<<"0x1">>, maps:get(<<"blockNumber">>, Tx)),
                           ?assertEqual(maps:get(<<"hash">>, lists:nth(2, Blocks)),
                                        maps:get(<<"blockHash">>, Tx))
                       end).

an_index_past_the_end_of_the_block_is_not_found_test() ->
    with_receipt_chain(fun(Chain, _Blocks) ->
                           ?assertEqual({error, not_found},
                                        eth_rpc_projection:transaction_at(Chain, 1, 99))
                       end).

a_negative_index_is_not_an_index_test() ->
    with_receipt_chain(fun(Chain, _Blocks) ->
                           ?assertEqual({error, not_found},
                                        eth_rpc_projection:transaction_at(Chain, 1, -1))
                       end).

%% The ByHashAndIndex pair, over the wire, because adding a dispatch clause with no
%% test for it is how `eth_getTransactionByBlockNumberAndIndex' ended up returning a
%% stored transaction with no `blockHash' for as long as it did: the method worked,
%% and worked wrongly, and nothing asked it about a field.
a_transaction_by_block_hash_and_index_carries_the_positional_fields_over_the_wire_test() ->
    with_receipt_chain_http(fun(Port) ->
                                {ok, #{<<"result">> := #{<<"hash">> := Hash}}} =
                                    rpc(Port, <<"eth_getBlockByNumber">>,
                                        [<<"0x1">>, false]),
                                {ok, #{<<"result">> := Tx}} =
                                    rpc(Port, <<"eth_getTransactionByBlockHashAndIndex">>,
                                        [Hash, <<"0x1">>]),
                                ?assertEqual(<<"0x1">>, maps:get(<<"transactionIndex">>, Tx)),
                                ?assertEqual(<<"0x1">>, maps:get(<<"blockNumber">>, Tx)),
                                ?assertEqual(Hash, maps:get(<<"blockHash">>, Tx))
                            end).

%% An index the block does not have is `null' -- the specification's `notFound' --
%% and not an error and not another block's transaction.
an_out_of_range_index_over_the_wire_is_null_test() ->
    with_receipt_chain_http(fun(Port) ->
                                {ok, #{<<"result">> := #{<<"hash">> := Hash}}} =
                                    rpc(Port, <<"eth_getBlockByNumber">>,
                                        [<<"0x1">>, false]),
                                {ok, #{<<"result">> := null}} =
                                    rpc(Port, <<"eth_getTransactionByBlockHashAndIndex">>,
                                        [Hash, <<"0x63">>])
                            end).

%% ===========================================================================
%% The one tag vocabulary
%% ===========================================================================
%%
%% `eth_getLogs' had its own copy of the tag resolution -- `log_num/2', beside a
%% `resolve_num/2' with identical clauses -- and this pass replaced both with
%% `eth_rpc_projection:resolve_block_number/2'. The two were free to drift, so
%% `finalized' could come to mean one height in a log filter and another in a block
%% lookup, and nothing would notice: both are just a number that happens to be in
%% range.
%%
%% A finalized checkpoint is set one below the head and the only log in the chain is
%% in the block *below* it, so `finalized' and `earliest' name different ranges. A
%% filter over the finalized range returns nothing; a filter that read `finalized' as
%% genesis returns the one log there is.

a_log_filter_reads_finalized_as_the_finalized_checkpoint_test() ->
    ok = eth_test_util:start_apps(),
    Chain = chain_log_filter,
    stop(Chain),
    {ok, _} = eth_chain:start_link(Chain, eth_test_util:tmp_dir()),
    try
        %% {Num, Transactions, BaseFee, GasUsed, GasLimit}, the shape
        %% `chain_blocks/2' threads parents through. The first version of this passed
        %% four-element tuples and read the gas limit out of the base fee's place.
        %% Block 0 carries a transaction, because a log belongs to a receipt and a
        %% receipt belongs to a transaction: `eth_getLogs' walks
        %% `zip(transactions, receipts)' and a block with no transactions has nothing
        %% to walk. The first version of this fixture gave block 0 no transactions and
        %% then expected a log in it, and the filter correctly returned nothing.
        Blocks = chain_blocks([{0, three_txs(16#c0), 1 * ?ONE_GWEI, 3000, 30000000},
                               {1, [], 1 * ?ONE_GWEI, 0, 30000000}], hex0()),
        ok = eth_chain:append(Chain, [{N, B, true} || {N, B} <- Blocks]),
        ok = eth_chain:put_receipts(Chain, 0, [receipt_with_log()]),
        ok = eth_chain:put_receipts(Chain, 1, []),
        ok = eth_chain:set_finalized(Chain, 1),
        Port = eth_test_util:free_port(),
        {ok, _} = eth_rpc_server:start_link(srv_log_filter,
                                            #{port => Port, chain => Chain,
                                              sync => 'no_such_sync_name'}),
        %% The upstream is pinned to a dead port, as in
        %% with_receipt_chain_http/1. A `getLogs' filter that fell back would otherwise
        %% query the configured endpoint -- a public Sepolia node -- and this test would
        %% pass or hang on the network. Here it made the point the hard way: the local
        %% scan threw, the filter proxied, and the test sat in httpc until it timed out.
        ok = eth_rpc_client:init(#{url => "http://127.0.0.1:1", timeout_ms => 200,
                                   retries => 0}),
        try
            Filter = #{<<"fromBlock">> => <<"finalized">>,
                       <<"toBlock">> => <<"finalized">>},
            %% The finalized checkpoint is the head, and the head has no logs, so the
            %% finalized range is empty.
            {ok, #{<<"result">> := []}} = rpc(Port, <<"eth_getLogs">>, [Filter]),
            %% Genesis is a *different* range, and it holds the only log in the chain.
            %% If `finalized' were read as genesis -- which is what an injection that
            %% maps the tag to 0 does -- this would return it and the assertion above
            %% would fail.
            {ok, #{<<"result">> := [Log]}} =
                rpc(Port, <<"eth_getLogs">>,
                    [Filter#{<<"fromBlock">> => <<"earliest">>,
                             <<"toBlock">> => <<"earliest">>}]),
            %% `[Log]' already says there is exactly one, and `Log' is that log --
            %% not a list of them. The first version asserted `length(Log)' on it,
            %% which is a length on a map.
            ?assertEqual(eth_hex:encode_int(0),
                         maps:get(<<"blockNumber">>, Log)),
            ?assertEqual(addr(30), maps:get(<<"address">>, Log))
        after
            ok = eth_rpc_client:init(#{url => eth_config:upstream_url(),
                                      timeout_ms => 20000}),
            (try gen_server:stop(srv_log_filter) catch _:_ -> ok end)
        end
    after
        stop(Chain)
    end.

%% One receipt carrying one log, so a scan that reaches block 0 has something to find.
%%
%% The topic is a 0x-hex *string*, as a stored receipt's is: receipts arrive from an
%% upstream as decoded RPC objects, and `eth_rpc_projection:enrich_logs/6' adds the
%% block context without re-encoding what is already there. A raw 32-byte topic is
%% therefore passed through to the JSON encoder, which raises `invalid_byte' and takes
%% the cowboy request handler down with it -- a crash rather than an error, for a
%% response the client never receives. That is not reachable from a real receipt, and
%% the first version of this fixture produced it by writing a topic as raw bytes.
receipt_with_log() ->
    (cum_receipt(21000))#{<<"logs">> =>
        [#{<<"address">> => addr(30),
           <<"topics">> => [<<"0x00000000000000000000000000000000000000000000000000000000000000aa">>],
           <<"data">> => <<"0x">>}]}.

%% ===========================================================================
%% eth_accounts
%% ===========================================================================

%% An empty array, and the correct answer rather than a placeholder: this node has
%% no keystore, no unlocked account and no signer, so the set of accounts it owns
%% is empty. Proxied, this returned the *upstream* node's accounts -- a different
%% node's answer to a question about this one.
%% Proved against an upstream that *does* have accounts, because otherwise the test
%% cannot tell a local answer from a proxied one: `eth_rpc_client' is process-wide and
%% another test module in the same VM points it somewhere, so an assertion of `[]'
%% alone would be satisfied by whatever that endpoint happened to say.
%%
%% The sentinel is the point. If this method proxies, the response carries the
%% upstream's address; it must carry `[]'.
%% Proved by making the upstream unreachable, because otherwise the test cannot tell a
%% local answer from a proxied one: `eth_rpc_client' is process-wide and another test
%% module in the same VM points it somewhere, so an assertion of `[]' on its own would
%% be satisfied by whatever that endpoint happened to say.
%%
%% A local answer does not care that the upstream is dead; a proxied one cannot
%% produce anything at all. The second assertion is the control that makes the first
%% meaningful -- it is the same dead upstream, and a method that *does* proxy fails.
accounts_answers_locally_rather_than_from_the_upstream_test() ->
    with_receipt_chain_http(fun(Port) ->
                                %% The upstream is already dead -- see
                                %% with_receipt_chain_http/1, which pins it there so a
                                %% fallback cannot reach the network from a test.
                                {ok, #{<<"result">> := []}} =
                                    rpc(Port, <<"eth_accounts">>, []),
                                %% The control: with the pool empty, this method has no
                                %% local answer and must fall back -- and the fallback
                                %% cannot reach anything.
                                {ok, #{<<"error">> := _}} =
                                    rpc(Port, <<"eth_maxPriorityFeePerGas">>, [])
                            end).

%% ===========================================================================
%% eth_maxPriorityFeePerGas
%% ===========================================================================

%% The minimum tip among the transactions that would be included next, which is
%% the same `tip/2' the builder orders its own selection by -- so the figure this
%% reports and the figure a proposer would earn are one number and not two.
the_suggested_tip_is_the_minimum_tip_among_the_transactions_that_would_be_included_test() ->
    Base = ?ONE_GWEI,
    %% Tips of 1, 3 and 2 gwei: the answer is the smallest of them, not the first
    %% in the list and not the largest.
    ?assertEqual({ok, 1 * ?ONE_GWEI},
                 eth_block_builder:min_includable_tip(
                   [entry(3, 1), entry(1, 5), entry(2, 9)], Base)).

%% A pool of includable transactions that bid no priority fee at all reports zero,
%% and that zero is derived rather than fabricated: it is the minimum tip over the
%% set this node would include, and the set is non-empty.
%%
%% The first version of the rule filtered on `tip > 0' and answered `undefined' here.
%% That reads to a client as "this node cannot say" when in fact it can, and it comes
%% from confusing the tip with the cap: a transaction with a 10 gwei cap and a zero
%% priority fee is includable against a 1 gwei base fee, and it is in the block.
a_pool_of_zero_tip_transactions_reports_zero_because_that_is_derived_test() ->
    Base = ?ONE_GWEI,
    ?assertEqual({ok, 0},
                 eth_block_builder:min_includable_tip([entry(0, 5), entry(0, 1)],
                                                      Base)).

%% EIP-1559's inclusion test is `maxFeePerGas >= baseFeePerGas' and nothing about
%% the tip, so the boundary is the cap against the base fee and one wei either side
%% of it is the whole rule. A transaction one wei short is not in the block whatever
%% it bids; one exactly at the base fee is.
a_transaction_that_cannot_pay_the_base_fee_is_not_a_candidate_test() ->
    Base = ?ONE_GWEI,
    ?assertEqual(undefined,
                 eth_block_builder:min_includable_tip(
                   [entry_cap(Base - 1, Base, 1)], Base)),
    ?assertEqual({ok, 0},
                 eth_block_builder:min_includable_tip(
                   [entry_cap(Base, 0, 1)], Base)),
    %% A non-candidate cannot drag the answer down, and an includable zero-tip
    %% transaction sets it. Order is irrelevant -- an excluded entry is excluded
    %% whatever order it is in.
    ?assertEqual({ok, 0},
                 eth_block_builder:min_includable_tip(
                   [entry_cap(Base - 1, Base, 1), entry_cap(Base, 0, 2)], Base)),
    ?assertEqual({ok, 4 * ?ONE_GWEI},
                 eth_block_builder:min_includable_tip(
                   [entry(4, 1), entry_cap(Base - 1, Base, 2)], Base)).

%% A legacy transaction's price *is* its cap, so the same test applies to it.
a_legacy_transaction_that_cannot_pay_the_base_fee_is_not_a_candidate_test() ->
    Base = ?ONE_GWEI,
    Short = #{tx => #{<<"gasPrice">> => eth_hex:encode_int(Base - 1)}},
    Exact = #{tx => #{<<"gasPrice">> => eth_hex:encode_int(Base)}},
    ?assertEqual(undefined, eth_block_builder:min_includable_tip([Short], Base)),
    ?assertEqual({ok, 0}, eth_block_builder:min_includable_tip([Exact], Base)).

an_empty_pool_reports_no_tip_rather_than_a_zero_one_test() ->
    ?assertEqual(undefined, eth_block_builder:min_includable_tip([], ?ONE_GWEI)).

%% The same tip formula the block builder selects on: a legacy transaction's tip
%% is its price less the burn, and a capped transaction's is its priority fee.
the_suggested_tip_uses_the_same_tip_formula_as_block_selection_test() ->
    Base = ?ONE_GWEI,
    Legacy = #{tx => #{<<"gasPrice">> => eth_hex:encode_int(5 * ?ONE_GWEI)}},
    Capped = #{tx => #{<<"maxPriorityFeePerGas">> =>
                           eth_hex:encode_int(2 * ?ONE_GWEI),
                       <<"maxFeePerGas">> => eth_hex:encode_int(4 * ?ONE_GWEI)}},
    %% The capped transaction's tip is min(2 gwei, 4 gwei - 1 gwei burn) = 2 gwei,
    %% and the legacy one pays 4 gwei, so the reported minimum is 2 gwei. The
    %% first version expected 4 gwei, having read the two figures as the two
    %% candidates without applying the cap.
    ?assertEqual({ok, 2 * ?ONE_GWEI},
                 eth_block_builder:min_includable_tip([Legacy, Capped], Base)).

%% The wiring, over a real pool and a real head: the figure comes from this node's
%% own state rather than being computed here.
a_suggested_tip_over_the_wire_comes_from_the_local_pool_test() ->
    with_pool_and_head(fun() ->
                           Tx = signed_tx(1),
                           {ok, _} = eth_txpool:add_map(
                                       eth_txpool,
                                       maps:remove(<<"_sender">>, Tx),
                                       funded(maps:get(<<"_sender">>, Tx))),
                           ?assertMatch({ok, _}, eth_block_builder:suggested_tip())
                       end).

%% No chain, so no head, so no next base fee, so no tip. Not an error and not a
%% zero: there is nothing to derive from.
a_chain_with_no_head_reports_no_suggested_tip_test() ->
    stop(eth_chain),
    ?assertEqual(undefined, eth_block_builder:suggested_tip()).

%% ===========================================================================
%% eth_getProof
%% ===========================================================================

%% The default `base_source' is `upstream': reads come from a peer and there is no
%% local trie. The specification's AccountProof is `additionalProperties: false'
%% with seven required fields, every one a fact about a state trie, and a peer
%% sends balances rather than the RLP nodes a proof is made of. So the honest
%% answer is that it cannot answer.
a_proof_is_refused_when_reads_come_from_upstream_test() ->
    ?assertEqual({error, {state_not_local, upstream}},
                 eth_rpc_projection:account_proof(?ADDR_HEX, [], <<"latest">>)).

%% With the local trie as the source, all seven required fields are present and the
%% account proof *verifies* against the state root the trie actually holds --
%% checked with eth_trie's own verifier rather than by comparing shapes, because
%% the whole output is a claim about that root.
an_account_proof_over_the_local_trie_has_every_required_field_and_verifies_test() ->
    with_local_state(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, eth_keccak:hash(<<>>)),
        Root = eth_mpt:state_root(),
        {ok, P} = eth_rpc_projection:account_proof(?ADDR_HEX, [], <<"latest">>),
        ?assertEqual([<<"accountProof">>, <<"address">>, <<"balance">>,
                      <<"codeHash">>, <<"nonce">>, <<"storageHash">>,
                      <<"storageProof">>],
                     lists:sort(maps:keys(P))),
        ?assertEqual(eth_hex:encode_int(1000), maps:get(<<"balance">>, P)),
        ?assertEqual(eth_hex:encode_int(7), maps:get(<<"nonce">>, P)),
        %% The proof verifies. The key is keccak256(address) by EIP-1052, which is
        %% what a client computes and what eth_mpt hashed under.
        Nodes = [un0x(N) || N <- maps:get(<<"accountProof">>, P)],
        {ok, AccountRLP} = eth_trie:verify_proof(Root, eth_keccak:hash(?ADDR_A),
                                                 Nodes),
        {ok, [Nonce, Balance, _StorageRoot, _CodeHash], <<>>} =
            eth_rlp:decode(AccountRLP),
        %% The trie stores scalars as minimal big-endian binaries, so a nonce of 7
        %% decodes as <<7>> -- an integer here would mean the proof was checked
        %% against a different encoding than the one the trie commits to.
        ?assertEqual(<<7>>, Nonce),
        ?assertEqual(<<16#03, 16#e8>>, Balance)
    end).

%% An account the local trie does not hold: refused, rather than answered with a
%% proof of an empty state -- which would be a valid-looking proof that the account
%% is empty when this node has simply never heard of it.
a_proof_of_an_account_the_local_trie_does_not_hold_is_refused_test() ->
    with_local_state(fun() ->
        ?assertEqual({error, account_not_local},
                     eth_rpc_projection:account_proof(hex0(16#bb), [],
                                                       <<"latest">>))
    end).

%% A storage key is `bytesMax32' -- the specification does not require 32 bytes --
%% and the storage trie's key is keccak256 of the slot as a *big-endian* word, so
%% a short key is left-padded. A right-padded short key hashes a different slot:
%% the client asks about slot 0x01 and receives a well-formed proof of some other
%% slot, with no way to tell from the response.
a_short_storage_key_is_left_padded_to_the_same_slot_test() ->
    with_local_state(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, eth_keccak:hash(<<>>)),
        ok = eth_mpt:put_storage(?ADDR_A, <<0:248, 1:256>>, 42),
        {ok, Short} = eth_rpc_projection:account_proof(?ADDR_HEX, [<<"0x1">>],
                                                        <<"latest">>),
        [SP] = maps:get(<<"storageProof">>, Short),
        ?assertEqual(66, byte_size(maps:get(<<"key">>, SP))),
        %% A binary and not a "string": in Erlang a quoted string is a *list*, and
        %% `"0x01"' =/= <<"0x01">>'. The first version of this compared against a
        %% string literal, which can never equal a value that came off the wire, and
        %% the failure it produced said nothing about the padding -- it read as a
        %% mismatch between two hex strings that are character-for-character equal.
        ?assertEqual(<<16#0:248, 1>>, un0x(maps:get(<<"key">>, SP))),
        ?assertEqual(eth_hex:encode_int(42), maps:get(<<"value">>, SP)),
        %% And the proof verifies against the account's own storage root.
        Nodes = [un0x(N) || N <- maps:get(<<"proof">>, SP)],
        {ok, StorageRoot} = eth_mpt:storage_root(?ADDR_A),
        ?assertMatch({ok, _},
                     eth_trie:verify_proof(StorageRoot,
                                           eth_keccak:hash(<<0:248, 1:256>>),
                                           Nodes)),
        %% And it is the same root the payload reports as `storageHash', so the
        %% proof is checked against the value the client is handed rather than
        %% against a second derivation of it.
        ?assertEqual(eth_hex:encode_bytes(StorageRoot),
                     maps:get(<<"storageHash">>, Short))
    end).

%% An absent slot is a real answer -- the value is zero -- and the proof of an
%% absent key is the nodes down to the divergence point, not an error.
a_proof_of_an_unset_storage_slot_reports_zero_test() ->
    with_local_state(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, eth_keccak:hash(<<>>)),
        {ok, P} = eth_rpc_projection:account_proof(?ADDR_HEX, [<<"0xdeadbeef">>],
                                                   <<"latest">>),
        [SP] = maps:get(<<"storageProof">>, P),
        ?assertEqual(eth_hex:encode_int(0), maps:get(<<"value">>, SP))
    end).

%% ===========================================================================
%% eth_estimateGas -- the search, and the classification
%% ===========================================================================

%% The least gas under which the call stops running out. Driven through least_gas/3
%% with a script of answers rather than through the EVM, because a test for a
%% binary search that has to stand up a state trie to watch it halve is a test that
%% will not be written.
the_search_finds_the_least_gas_that_does_not_run_out_test() ->
    ?assertEqual({ok, 21000},
                 eth_call:least_gas(succeeds_above(21000), 0, 100000)).

%% A gas estimate is the *least* sufficient figure, not any sufficient one: a
%% client sending a loose ceiling wastes it.
the_search_converges_on_the_least_sufficient_figure_test() ->
    ?assertEqual({ok, 42001},
                 eth_call:least_gas(succeeds_above(42001), 0, 1000000)).

%% A call that never completes is an error, not a number. Reporting the block gas
%% limit would be a gas figure for a transaction that cannot be included, and a
%% client would send it.
a_call_that_always_runs_out_of_gas_is_an_error_and_not_a_number_test() ->
    ?assertEqual({error, always_out_of_gas},
                 eth_call:least_gas(fun(_G) -> out_of_gas end, 0, 30000000)).

%% A transaction that is *rejected* -- an invalid opcode, a write under a static
%% call, an insufficient balance -- fails at any gas limit. The search must stop
%% and report the reason rather than walking to the ceiling and reporting a gas
%% figure, which would be a number nobody can use.
a_rejection_stops_the_search_and_is_reported_test() ->
    %% Rejected at *every* gas limit, which is what an invalid opcode, a write under
    %% a static call and an insufficient balance each mean: no amount of gas makes
    %% the call run.
    %%
    %% The first version of this rejected only at the ceiling -- the figure the
    %% search probes first -- so it proved that an error at the ceiling is reported
    %% and said nothing about a rejection found part way down. An injection that
    %% treated a mid-search rejection as "needs more gas" and walked on to the
    %% ceiling did not fail it, and would have answered `{ok, 30000000}' for a
    %% transaction that can never run: a gas estimate, for something unsendable.
    ?assertEqual({error, insufficient_balance},
                 eth_call:least_gas(fun(_G) -> {error, insufficient_balance} end,
                                    0, 30000000)),
    ?assertEqual({error, invalid_opcode},
                 eth_call:least_gas(fun(_G) -> {error, invalid_opcode} end,
                                    0, 30000000)),
    %% And the ceiling probe on its own, which is the case that did pass before, and
    %% the reachable one: a transaction this node cannot run is rejected identically at
    %% every gas limit, so the first probe is where it is found.
    ?assertEqual({error, write_protection},
                 eth_call:least_gas(fun(30000000) -> {error, write_protection};
                                       (_G) -> ok
                                    end, 0, 30000000)),
    %% A rejection found *part way down* the search, with the ceiling succeeding. This
    %% ordering cannot arise on a real chain -- the reasons the EVM reports other than
    %% out-of-gas do not depend on the gas limit -- so the runner is synthetic. It is
    %% here because the branch is a real branch, and a branch with no test is a branch
    %% that can be inverted: treating a mid-search rejection as "needs more gas" walks
    %% the rest of the range and answers a gas figure for a call that cannot run.
    ?assertEqual({error, invalid_opcode},
                 eth_call:least_gas(fun(G) when G >= 100000 -> ok;
                                       (_G) -> {error, invalid_opcode}
                                    end, 0, 30000000)).

%% A revert is not an out-of-gas. The gas a reverting call burns is real, and a
%% client asking what it will cost is owed the answer rather than an error. The
%% first version treated a revert as a failure, so every reverting call was
%% reported as "always fails" -- an error where a figure was correct.
a_revert_counts_as_success_because_a_revert_burns_real_gas_test() ->
    ?assertEqual(ok, eth_call:classify({revert, <<>>})),
    ?assertEqual(ok, eth_call:classify({ok, <<>>})),
    ?assertEqual(out_of_gas, eth_call:classify({error, out_of_gas})),
    ?assertEqual({error, invalid_opcode},
                 eth_call:classify({error, invalid_opcode})).

%% ===========================================================================
%% Fixtures
%% ===========================================================================

%% Four post-Merge blocks, linked by their real hashes so the chain's own parent
%% check passes. Block 0 has no transactions; blocks 1 and 2 have three each; block
%% 3 exists to be a parent. Receipts are stored for 0 and 1 only, so block 2 is the
%% pruned-history case.
with_receipt_chain(Fun) ->
    with_fresh_chain(fun(Chain) ->
                         Blocks = linked_blocks(),
                         ok = eth_chain:append(Chain, [{N, B, true}
                                                       || {N, B} <- Blocks]),
                         ok = eth_chain:put_receipts(Chain, 0, []),
                         ok = eth_chain:put_receipts(Chain, 1, cum_receipts()),
                         Fun(Chain, [B || {_, B} <- Blocks])
                     end).

%% The same chain behind an HTTP endpoint, for the wire-shape assertions, with the
%% upstream pointed at a port nothing is listening on.
%%
%% That is not tidiness. `eth_rpc_client' is process-wide, and a handler clause that
%% falls back to the proxy will therefore reach whatever endpoint the last test
%% configured -- on this project, a public Sepolia node. A test whose *failure* path
%% runs an upstream query is a test that passes on a network and hangs without one, and
%% a unit test must never perform a lazy upstream fetch. With the upstream dead, a
%% proxied method fails immediately and offline, and the difference between "answered
%% locally" and "fell back" is visible in the response: a local answer, or an error.
%%
%% `retries => 0' so the fallback does not wait three times over, and the configured
%% endpoint is restored on the way out so no later module inherits a dead port.
with_receipt_chain_http(Fun) ->
    with_receipt_chain(fun(Chain, _Blocks) ->
                           Port = eth_test_util:free_port(),
                           {ok, _} = eth_rpc_server:start_link(
                                       srv_rpc_extra,
                                       #{port => Port, chain => Chain,
                                         sync => 'no_such_sync_name'}),
                           ok = eth_rpc_client:init(
                                  #{url => "http://127.0.0.1:1", timeout_ms => 200,
                                    retries => 0}),
                           try Fun(Port)
                           after
                               ok = eth_rpc_client:init(
                                      #{url => eth_config:upstream_url(),
                                        timeout_ms => 20000}),
                               (try gen_server:stop(srv_rpc_extra)
                                catch _:_ -> ok end)
                           end
                       end).

%% Three blocks for the feeHistory shape assertions. Block 0 carries a base fee;
%% block 1 is pre-EIP-1559 and has none, which is what the zero-base-fee test
%% reads. No receipts stored anywhere.
with_chain(Fun) ->
    with_fresh_chain(fun(Chain) ->
                         Blocks = fee_linked_blocks(),
                         ok = eth_chain:append(Chain, [{N, B, true}
                                                       || {N, B} <- Blocks]),
                         Fun(Chain, [B || {_, B} <- Blocks])
                     end).

%% The same chain with receipts stored, for the reward assertions. Block 1 holds
%% three transactions whose tips are 1, 3 and 4 gwei at 1000 gas each.
%% The same chain as `with_receipt_chain/1' -- blocks 1 and 2 carry three
%% transactions -- with receipts stored for blocks 0 and 1. The reward tests need a
%% block that has *both* transactions and their gas figures, and the first version of
%% this fixture used the fee-history blocks, which have no transactions at all: so
%% the distribution was built from three receipts and no transactions to price, and
%% `lists:zip/2' raised on a length mismatch rather than answering.
with_tip_chain(Fun) ->
    with_fresh_chain(fun(Chain) ->
                         Blocks = linked_blocks(),
                         ok = eth_chain:append(Chain, [{N, B, true}
                                                       || {N, B} <- Blocks]),
                         ok = eth_chain:put_receipts(Chain, 0, []),
                         ok = eth_chain:put_receipts(Chain, 1, cum_receipts()),
                         Fun(Chain)
                     end).

%% A fresh store, stopped on the way out. `eth_chain' is a singleton registered
%% under its own name and another test module in the same VM may have left one
%% running with block 0 already stored from a different parent -- which the chain's
%% own parent check then refuses, as `missing_parent'.
with_fresh_chain(Fun) ->
    ok = eth_test_util:start_apps(),
    Chain = chain_rpc_extra,
    stop(Chain),
    {ok, _} = eth_chain:start_link(Chain, eth_test_util:tmp_dir()),
    try Fun(Chain)
    after stop(Chain)
    end.

%% Blocks are hashed and linked the way the store will verify them: the parent hash
%% is the previous block's computed hash, not a transcribed one. A hand-written
%% parent would make the append fail for a reason that has nothing to do with the
%% method under test.
%% Four post-Merge blocks, all at a 1 gwei base fee, which is the base fee
%% `three_txs/0' tips are quoted against.
linked_blocks() ->
    chain_blocks([{0, [], 1 * ?ONE_GWEI, 0, 30000000},
                  {1, three_txs(16#a0), 1 * ?ONE_GWEI, 3000, 30000000},
                  {2, three_txs(16#b0), 1 * ?ONE_GWEI, 3000, 30000000},
                  {3, [], 1 * ?ONE_GWEI, 0, 30000000}], hex0()).

%% Threaded rather than by looking each block's parent out of the list being built
%% -- which is not a tail call but an unbounded recursion, and it loops until eunit
%% cancels the test with no assertion in sight. Named `chain_blocks' and not `link'
%% because `link/1,2' is a BIF.
%%
%% A base fee of 0 means "this block has no `baseFeePerGas' field at all", which is
%% how a pre-EIP-1559 block is spelled. Without removing the field every block
%% would carry one and the pre-1559 assertion would have nothing to read; a zero
%% base fee on a post-1559 block is a real value this fixture does not use, so the
%% two cases are not confused here.
chain_blocks([], _Prev) ->
    [];
chain_blocks([{Num, Txs, BaseFee, Used, Limit} | Rest], Prev) ->
    Block = with_hash(Num, Prev, Txs, Used, Limit, BaseFee),
    [{Num, Block} | chain_blocks(Rest, maps:get(<<"hash">>, Block))].

%% The hash is stored in its canonical 0x-hex form, not as the 32 raw bytes
%% `eth_header:hash/1' returns, for two reasons that are the same reason.
%%
%% The next block's `parentHash' has to be that hex string: `eth_header' reads
%% `parentHash' through `data_value/1' -> `hex_to_bin/1', which converts a *hex
%% string* to bytes and has no binary clause. Handed the raw 32 bytes it converts
%% them to a list of integers and asks `hexval/1' about each -- so a real block
%% hash whose first byte is 0x15 dies in `hexval(21)`, a function_clause that
%% names neither the fixture nor the field. And `eth_chain` re-verifies each block
%% on append and writes the *hex* form back, so a store seeded with raw bytes and
%% a store seeded with hex would disagree about every hash.
%% A base fee of 0 means the field is *absent*, which is how a pre-EIP-1559 block
%% is spelled. The field is removed before the hash is taken, not after: the hash
%% is a commitment to the header as stored, and hashing a header that still had a
%% base fee and then storing one without it is a block whose hash the store's own
%% re-verification rejects as `bad_block_hash'. That is the check working.
with_hash(Num, PH, Txs, Used, Limit, BaseFee) ->
    With = (eth_test_util:header(Num, PH, 0))#{
             <<"baseFeePerGas">> => eth_hex:encode_int(BaseFee),
             <<"gasUsed">> => eth_hex:encode_int(Used),
             <<"gasLimit">> => eth_hex:encode_int(Limit),
             <<"totalDifficulty">> => eth_hex:encode_int(0),
             <<"transactions">> => Txs},
    Map = case BaseFee of
              0 -> maps:remove(<<"baseFeePerGas">>, With);
              _ -> With
          end,
    {ok, Hash} = eth_header:hash(Map),
    Map#{<<"hash">> => eth_hex:encode_bytes(Hash)}.

%% Three transactions with distinct tips against a 1 gwei base fee: 1 gwei, 3 gwei,
%% and a legacy one paying 5 gwei of which 1 gwei is burned.
%%
%% The hashes are prefixed per block, and both matters. A transaction hash is
%% globally unique, so two blocks in one fixture carrying the same three hashes is
%% a fixture that says two different transactions have one identity -- and the store
%% indexes transactions by hash, so the later block silently overwrites the earlier
%% one and every "which block is this transaction in" answer names the wrong block.
%% The prefix also puts hex letters in the hash, so the case-normalisation test has
%% something to normalise: `"0x1"' upper-cases to itself.
three_txs(Prefix) ->
    [#{<<"hash">> => eth_hex:encode_bytes(<<Prefix:8>>),
        <<"from">> => addr(10), <<"to">> => addr(20),
       <<"nonce">> => <<"0x0">>, <<"gas">> => <<"0x5208">>, <<"value">> => <<"0x0">>,
       <<"maxPriorityFeePerGas">> => eth_hex:encode_int(1 * ?ONE_GWEI),
       <<"maxFeePerGas">> => eth_hex:encode_int(10 * ?ONE_GWEI),
       <<"type">> => <<"0x2">>},
     #{<<"hash">> => eth_hex:encode_bytes(<<Prefix:8, 2>>),
        <<"from">> => addr(11), <<"to">> => addr(21),
       <<"nonce">> => <<"0x1">>, <<"gas">> => <<"0x5208">>, <<"value">> => <<"0x0">>,
       <<"maxPriorityFeePerGas">> => eth_hex:encode_int(3 * ?ONE_GWEI),
       <<"maxFeePerGas">> => eth_hex:encode_int(10 * ?ONE_GWEI),
       <<"type">> => <<"0x2">>},
     #{<<"hash">> => eth_hex:encode_bytes(<<Prefix:8, 3>>),
        <<"from">> => addr(12), <<"to">> => addr(22),
       <<"nonce">> => <<"0x2">>, <<"gas">> => <<"0x5208">>, <<"value">> => <<"0x0">>,
       <<"gasPrice">> => eth_hex:encode_int(5 * ?ONE_GWEI),
       <<"type">> => <<"0x0">>}].

%% 20 bytes, 0x-prefixed -- an address. `eth_hex:encode_int/1' is a *quantity*
%% encoder, so `hex0(20)' is `"0x14"' -- one byte -- and a transaction naming it as
%% `to' is rejected by the pool as `invalid_to'. The first version of the signed
%% fixture did exactly that.
addr(N) -> eth_hex:encode_bytes(<<N:160>>).

%% Receipts carrying only cumulative gas, 1000 at a time, so `gasUsed' has to be
%% derived as a difference.
cum_receipts() ->
    [cum_receipt(1000), cum_receipt(2000), cum_receipt(3000)].

cum_receipt(Cum) ->
    #{<<"type">> => <<"0x0">>, <<"status">> => <<"0x1">>,
      <<"cumulative_gas_used">> => eth_hex:encode_int(Cum),
      <<"logs">> => [], <<"logsBloom">> => <<"0x">>}.

%% feeHistory's shape fixture. Block 0 is post-1559 with half its gas limit used,
%% block 1 is pre-1559 and has no base fee at all, and block 2 -- the head, and so
%% `latest' -- is post-1559 at 2 gwei. The head has to be: `eth_feeHistory' derives
%% one base fee *past* the newest returned block from that block's own fields, and a
%% pre-1559 head has none to derive from. An earlier version made blocks 1 and 2
%% pre-1559 and then read the head as post-1559, which is a contradiction that only
%% showed up as a failed assertion about a base fee.
fee_linked_blocks() ->
    chain_blocks([{0, [], 1 * ?ONE_GWEI, 15000000, 30000000},
                  {1, [], 0, 7000000, 30000000},
                  {2, [], 2 * ?ONE_GWEI, 3000000, 30000000}], hex0()).

%% A pool holding one transaction, and a chain whose head declares a base fee, so
%% `suggested_tip/0' has both of its inputs. The pool holds a genuinely signed
%% transaction because `eth_txpool:add_map/3' re-encodes it -- an unsigned map
%% would not be a transaction.
with_pool_and_head(Fun) ->
    ok = eth_test_util:start_apps(),
    stop(eth_chain),
    stop(eth_txpool),
    {ok, _} = eth_chain:start_link(eth_chain, eth_test_util:tmp_dir()),
    {ok, _} = eth_txpool:start_link(#{name => eth_txpool}),
    Blocks = [{0, with_hash(0, hex0(), [], 0, 30000000, 10 * ?ONE_GWEI)}],
    ok = eth_chain:append(eth_chain, [{N, B, true} || {N, B} <- Blocks]),
    try Fun()
    after stop(eth_txpool), stop(eth_chain)
    end.

%% A real signed type-2 transaction, because `eth_txpool:add_map/3' re-encodes the
%% transaction and validates its signature: an unsigned map is not a transaction.
%%
%% Type 2 and not legacy, and that is not a detail. `eth_tx:sighash/1` picks the
%% preimage from the transaction's own type, and the two disagree completely: a
%% legacy `v' of 27/28 or 35 + 2*chainId is meaningless to a type-2 sighash, which
%% takes `v' as the bare recovery id. A transaction carrying a legacy `v' *and*
%% `maxPriorityFeePerGas' is therefore read as type 2 -- `tx_type/1' decides on the
%% presence of the fee fields -- and its recovery id comes out as a six-digit
%% number, `recover' refuses it, and the pool answers `bad_signature'. That names the
%% signature rather than the type confusion behind it, and the first version of this
%% fixture produced exactly that.
%%
%% The preimage here is `eth_tx:sighash/1`'s, field for field: chain id, nonce,
%% priority fee, cap, gas, to, value, data, access list -- behind a 0x02 byte.
signed_tx(PriorityGwei) ->
    Priv = eth_secp256k1:generate_key(),
    %% The funded account has to be the one the signature recovers to, which is
    %% derived from the public key and is not an address the test chose. Funding
    %% some other address funds an account nobody signed for, and the pool's refusal
    %% names the balance rather than the mismatch.
    Sender = eth_hex:encode_bytes(address_of(Priv)),
    ChainId = eth_fork_schedule:chain_id(),
    Priority = PriorityGwei * ?ONE_GWEI,
    Cap = 10 * ?ONE_GWEI,
    Pay = [ChainId, 0, Priority, Cap, 21000, <<20:160>>, 0, <<>>, []],
    Digest = eth_keccak:hash(<<16#02, (eth_rlp:encode(Pay))/binary>>),
    {R, S0, V0} = eth_secp256k1:sign(Digest, Priv),
    %% EIP-2 requires the low half of the curve order, and `valid_signature/1`
    %% enforces it. Normalising also flips the recovery parity, so the address that
    %% comes back is the one the key actually has.
    {S, V} = low_s(S0, V0),
    Base = #{<<"type">> => <<"0x2">>,
            <<"chainId">> => eth_hex:encode_int(ChainId),
            <<"nonce">> => <<"0x0">>,
            <<"maxPriorityFeePerGas">> => eth_hex:encode_int(Priority),
            <<"maxFeePerGas">> => eth_hex:encode_int(Cap),
            <<"gas">> => <<"0x5208">>,
            <<"to">> => addr(20),
            <<"value">> => <<"0x0">>,
            <<"input">> => <<"0x">>,
            <<"accessList">> => [],
            <<"v">> => eth_hex:encode_int(V),
            <<"r">> => eth_hex:encode_int(R),
            <<"s">> => eth_hex:encode_int(S)},
    Base#{<<"_sender">> => Sender}.

%% An account funded enough for the pool to accept the transaction, as the snapshot
%% the pool validates against: an `eth_state' with a balance and a nonce set, keyed
%% by a 0x-hex address. A plain map of address to {balance, nonce} is not that shape,
%% and the pool's readers find nothing in it.
funded(Address) ->
    S0 = eth_state:new(#{}, #{}),
    S1 = eth_state:set_balance(S0, Address, 1000000000000000000),
    eth_state:set_nonce(S1, Address, 0).

%% secp256k1 group order; EIP-2 requires 1 <= r,s < N and s in the low half.
-define(SECP_N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).

low_s(S, V) when S > (?SECP_N div 2) -> {?SECP_N - S, 1 - V};
low_s(S, V) -> {S, V}.

%% The recovered address of a private key: the low 20 bytes of keccak256 of the
%% uncompressed public key, which is how every Ethereum address is derived.
address_of(Priv) ->
    binary:part(eth_keccak:hash(eth_ecies:pubkey(Priv)), 12, 20).

%% A pool entry as `eth_txpool:pending/1' returns it: the transaction map plus the
%% bookkeeping, of which only `tx' matters to a tip.
%% `TipGwei' is in gwei because every test that reads it thinks in gwei, and a
%% fixture that made them multiply by a billion is a fixture that will be read
%% wrong. The first version took a bare number and the tests that said "1 gwei"
%% passed 1 wei -- an answer 10^9 off that still looked like a number.
%% Quoted in wei rather than gwei, for the two assertions that sit exactly on the
%% boundary where a transaction stops being includable. `entry/2' multiplies by
%% gwei, so asking it for "exactly the base fee" would have meant 10^18 gwei.
%% Cap and tip both quoted in wei, for the inclusion boundary -- which is a test of
%% the *cap*. `entry_wei/2' moves the tip and leaves the cap ten gwei above, so
%% asking it about a cap one wei short of the base fee asked about nothing.
entry_cap(CapWei, PrioWei, Nonce) ->
    #{tx => #{<<"maxPriorityFeePerGas">> => eth_hex:encode_int(PrioWei),
              <<"maxFeePerGas">> => eth_hex:encode_int(CapWei)},
      sender => addr(10), nonce => Nonce, price => 0, cost => 0, base_nonce => 0}.

entry(TipGwei, Nonce) ->
    #{tx => #{<<"maxPriorityFeePerGas">> => eth_hex:encode_int(TipGwei * ?ONE_GWEI),
              <<"maxFeePerGas">> => eth_hex:encode_int(10 * ?ONE_GWEI)},
      sender => addr(10), nonce => Nonce, price => 0, cost => 0, base_nonce => 0}.

%% The MPT is a registered singleton and `base_source' is process-wide, so both are
%% restored here or another module's reads are redirected for the rest of the run.
%% This is what `eth_test_util:finalize_ctx/1' exists for.
with_local_state(Fun) ->
    _ = ensure_started(eth_mpt),
    ok = eth_mpt:clear(),
    Previous = eth_state:base_source(),
    ok = eth_state:set_base_source(mpt),
    try Fun()
    after
        ok = eth_state:set_base_source(Previous),
        _ = eth_mpt:clear()
    end.

ensure_started(Mod) ->
    case whereis(Mod) of
        undefined -> {ok, P} = Mod:start_link(), P;
        Pid -> Pid
    end.

stop(Mod) ->
    case whereis(Mod) of
        undefined -> ok;
        _ -> (try gen_server:stop(Mod) catch _:_ -> ok end)
    end.

%% A runner that needs at least `Threshold' gas -- the script the search tests use
%% in place of the EVM. The boundary is inclusive, so a test can name the exact
%% figure it expects the search to converge on.
succeeds_above(Threshold) ->
    fun(G) when G >= Threshold -> ok;
       (_) -> out_of_gas
    end.

gas_of(Block, Key) -> eth_hex:decode(maps:get(Key, Block, <<"0x0">>)).

upper(<<"0x", Rest/binary>>) -> <<"0x", (string:uppercase(Rest))/binary>>;
upper(Other) -> Other.

un0x(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
un0x(B) -> B.

hex0() -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>.
hex0(N) -> eth_hex:encode_int(N).

rpc(Port, Method, Params) ->
    Body = thoas:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
                          <<"method">> => Method, <<"params">> => Params}),
    {ok, {{_, 200, _}, _, Resp}} =
        httpc:request(post, {"http://127.0.0.1:" ++ integer_to_list(Port),
                             [{"content-type", "application/json"}],
                             "application/json", Body},
                      [{timeout, 10000}], [{body_format, binary}]),
    thoas:decode(Resp).
