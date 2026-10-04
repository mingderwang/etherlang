-module(eth_chain).
-behaviour(gen_server).

%% Canonical-chain store.
%%
%% Blocks are persisted in DETS files under the data directory. Each block is
%% stored with a `Full' flag: `true' means the transactions array holds full
%% transaction objects, `false' means it only holds transaction hashes
%% (i.e. we fetched header-only). Only canonical blocks are kept; reorgs are
%% detected through parent-hash linkage and handled by rewinding the head.
%%
%% Integrity: unless `VERIFY_HEADERS=false', every appended block's header is
%% re-hashed (RLP + keccak-256) and must match its claimed `hash'; the stored
%% canonical hash is the recomputed one, so parent linkage is cryptographic.
%% A `finalized' checkpoint (fetched from upstream) is persisted and forms a
%% hard floor: the chain is never rewound below it.
%%
%% Storage layout (DETS "set" tables):
%%   num_tab   : {{Num}}        -> {Hash, Block, Full}
%%   hash_tab  : {{Hash}}       -> Num
%%   receipts  : {{Num}}        -> [ReceiptMap]
%%   meta_tab  : head           -> {Num, Hash}
%%               finalized      -> Num
%%               low            -> Num  (lowest block number still retained)
%%
%% Bounded growth: DETS files cannot exceed 2 GiB, so the store keeps only a
%% recent window. After each append, blocks below
%%   max(head - retention + 1, 0)
%% are deleted from both tables (the `low' watermark makes this incremental).
%% The `finalized' checkpoint itself is always kept so `rewind' to it stays
%% possible. Older blocks are served from the upstream proxy instead (the RPC
%% layer already falls back on `not_found').

-export([start_link/1, start_link/2,
         head/0, head/1,
         append/1, append/2,
         rewind/1, rewind/2,
         get_by_number/1, get_by_number/2,
         get_by_hash/1, get_by_hash/2,
         receipts/1, receipts/2, put_receipts/2, put_receipts/3,
         tx_block/1, tx_block/2,
         canonical_hash/1, canonical_hash/2,
         highest/1, has_block/1, has_block/2, size/1,
         finalized/0, finalized/1, set_finalized/2,
         get_gas_used/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Max keys removed per prune pass; bounds the work done in a single append if
%% a pre-existing (unbounded) store has to catch up.
-define(PRUNE_BATCH, 4096).

-record(st, {dir, head :: undefined | {integer(), binary()},
             finalized :: undefined | integer(),
             low = 0 :: integer(),
             retention = 2048 :: integer(),
             verify = true :: boolean(),
             num_tab = num_tab,
             hash_tab = hash_tab,
             meta_tab = meta_tab,
             receipts_tab = receipts_tab,
             tx_tab = tx_tab}).

start_link(Dir) -> start_link(eth_chain, Dir).
start_link(Name, Dir) when is_atom(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Dir}, []).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

head() -> head(eth_chain).
head(Name) -> gen_server:call(Name, head).

%% Append canonical blocks, ascending by number. Each entry is {Num, Block, Full}.
%% Returns: ok | {reorg, CommonAncestorNum} | {missing_parent, ParentHash}
%%        | {error, {bad_block, Num, Reason}} | {error, {below_finality, Num}}.
append(Blocks) when is_list(Blocks) -> append(eth_chain, Blocks).
append(Name, Blocks) when is_list(Blocks) ->
    gen_server:call(Name, {append, Blocks}).

%% Rewind the canonical head to Num, discarding everything above it. Refuses to
%% go below the finalized checkpoint.
rewind(N) -> rewind(eth_chain, N).
rewind(Name, N) -> gen_server:call(Name, {rewind, N}).

get_by_number(N) -> get_by_number(eth_chain, N).
get_by_number(Name, N) -> gen_server:call(Name, {get_by_number, N}).

get_by_hash(H) -> get_by_hash(eth_chain, H).
get_by_hash(Name, H) -> gen_server:call(Name, {get_by_hash, H}).

%% Stored receipts for a block number: {ok, [ReceiptMap]} | not_found.
receipts(N) -> receipts(eth_chain, N).
receipts(Name, N) -> gen_server:call(Name, {receipts, N}).

put_receipts(N, Receipts) -> put_receipts(eth_chain, N, Receipts).
put_receipts(Name, N, Receipts) -> gen_server:call(Name, {put_receipts, N, Receipts}).

%% Block number containing a transaction hash.
tx_block(TxHash) -> tx_block(eth_chain, TxHash).
tx_block(Name, TxHash) -> gen_server:call(Name, {tx_block, TxHash}).

canonical_hash(N) -> canonical_hash(eth_chain, N).
canonical_hash(Name, N) -> gen_server:call(Name, {canonical_hash, N}).

highest(Name) -> gen_server:call(Name, highest).

has_block(N) -> has_block(eth_chain, N).
has_block(Name, N) ->
    case try gen_server:call(Name, {get_by_number, N}) catch _:_ -> error end of
        {ok, _, _} -> true;
        _ -> false
    end.

size(Name) -> gen_server:call(Name, size).

finalized() -> finalized(eth_chain).
finalized(Name) -> gen_server:call(Name, finalized).

%% Advance the finalized checkpoint (monotonic; never goes backwards).
set_finalized(Name, Num) when is_integer(Num), Num >= 0 ->
    gen_server:call(Name, {set_finalized, Num}).

get_gas_used(Number) -> get_gas_used(eth_chain, Number).

get_gas_used(Name, Number) -> gen_server:call(Name, {gas_used, Number}).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init({Name, Dir}) ->
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Prefix = atom_to_list(Name) ++ "_",
    NumTab = list_to_atom(Prefix ++ "num_tab"),
    HashTab = list_to_atom(Prefix ++ "hash_tab"),
    MetaTab = list_to_atom(Prefix ++ "meta_tab"),
    ReceiptsTab = list_to_atom(Prefix ++ "receipts_tab"),
    TxTab = list_to_atom(Prefix ++ "tx_tab"),
    {ok, _} = dets:open_file(NumTab, [{file, filename:join(Dir, "chain.num.dets")},
                                      {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(HashTab, [{file, filename:join(Dir, "chain.hash.dets")},
                                       {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(MetaTab, [{file, filename:join(Dir, "chain.meta.dets")},
                                       {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(ReceiptsTab, [{file, filename:join(Dir, "chain.receipts.dets")},
                                           {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(TxTab, [{file, filename:join(Dir, "chain.tx.dets")},
                                     {type, set}, {repair, force}]),
    Head = case dets:lookup(MetaTab, head) of
               [{head, {N, H}}] -> {N, H};
               _ -> undefined
           end,
    Fin = case dets:lookup(MetaTab, finalized) of
              [{finalized, F}] when is_integer(F) -> F;
              _ -> undefined
          end,
    Retention = max(eth_config:chain_retention(), eth_config:max_reorg_depth()),
    %% `low' is the lowest block we may still have; seed it near the head when
    %% absent (first start of a pre-existing store) so pruning starts in the
    %% right place instead of walking up from zero.
    Low = case dets:lookup(MetaTab, low) of
              [{low, L}] when is_integer(L) -> L;
              _ ->
                  case Head of
                      {HN0, _} -> max(HN0 - Retention, 0);
                      undefined -> 0
                  end
          end,
    _ = Name,
    check_consistency(NumTab, HashTab, MetaTab, Head),
    {ok, #st{dir = Dir, head = Head, finalized = Fin, low = Low,
             retention = Retention,
             verify = eth_config:verify_headers(),
             num_tab = NumTab, hash_tab = HashTab, meta_tab = MetaTab,
             receipts_tab = ReceiptsTab, tx_tab = TxTab}}.

handle_call(head, _From, S) ->
    {reply, S#st.head, S};

handle_call(highest, _From, #st{head = undefined} = S) ->
    {reply, -1, S};
handle_call(highest, _From, #st{head = {N, _}} = S) ->
    {reply, N, S};

handle_call(size, _From, S) ->
    {reply, dets:info(S#st.num_tab, size), S};

handle_call({canonical_hash, N}, _From, S) ->
    {reply, lookup_canonical(S, N), S};

handle_call({get_by_number, N}, _From, S) ->
    case dets:lookup(S#st.num_tab, {N}) of
        [{{N}, {_Hash, Block, Full}}] -> {reply, {ok, Block, Full}, S};
        [] -> {reply, not_found, S}
    end;

handle_call({get_by_hash, H}, _From, S) ->
    case dets:lookup(S#st.hash_tab, {H}) of
        [{{H}, N}] ->
            case dets:lookup(S#st.num_tab, {N}) of
                [{{N}, {_Hash2, Block, Full}}] -> {reply, {ok, Block, Full}, S};
                [] -> {reply, not_found, S}
            end;
        [] ->
            {reply, not_found, S}
    end;

handle_call({receipts, N}, _From, S) ->
    case dets:lookup(S#st.receipts_tab, {N}) of
        [{{N}, Receipts}] -> {reply, {ok, Receipts}, S};
        [] -> {reply, not_found, S}
    end;

handle_call({put_receipts, N, Receipts}, _From, S) when is_integer(N), is_list(Receipts) ->
    ok = dets:insert(S#st.receipts_tab, {{N}, Receipts}),
    {reply, ok, S};
handle_call({put_receipts, _, _}, _From, S) ->
    {reply, {error, bad_arg}, S};

handle_call({tx_block, TxHash}, _From, S) ->
    case dets:lookup(S#st.tx_tab, {TxHash}) of
        [{{TxHash}, Num}] -> {reply, {ok, Num}, S};
        [] -> {reply, not_found, S}
    end;

handle_call({append, Blocks}, _From, S) ->
    case verify_blocks(Blocks, S#st.verify, S) of
        {ok, Blocks1} ->
            {Res, S1} = do_append(Blocks1, S),
            S2 = case Res of
                     ok -> prune(S1);
                     _ -> S1
                 end,
            {reply, Res, S2};
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end;

handle_call({rewind, N}, _From, S) ->
    case below_finality(S, N) of
        true ->
            {reply, {error, {below_finality, S#st.finalized}}, S};
        false ->
            {reply, ok, rewind_to(S, N)}
    end;

handle_call(finalized, _From, S) ->
    {reply, S#st.finalized, S};

handle_call({set_finalized, N}, _From, #st{finalized = F} = S) when F =/= undefined, N =< F ->
    {reply, ok, S};
handle_call({set_finalized, N}, _From, S) ->
    ok = dets:insert(S#st.meta_tab, {finalized, N}),
    {reply, ok, S#st{finalized = N}};
handle_call({gas_used, N}, _From, S) ->
    Reply = case dets:lookup(S#st.num_tab, {N}) of
        [{{N}, {_Hash, Block, _Full}}] -> {ok, maps:get(<<"gasUsed">>, Block, 0)};
        [] -> not_found
    end,
    {reply, Reply, S};

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S) ->
    lists:foreach(fun(T) ->
                          _ = try dets:close(T) catch _:_ -> ok end
                  end, [S#st.num_tab, S#st.hash_tab, S#st.meta_tab,
                        S#st.receipts_tab, S#st.tx_tab]),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

do_append([], S) ->
    {ok, S};
do_append([{Num, Block, Full} | Rest], #st{head = undefined} = S) ->
    %% No head yet: accept this as the anchor block (genesis or snapshot start).
    Hash = block_hash(Block),
    do_append(Rest, set_low(insert(S, Num, Hash, Block, Full), Num));
do_append([{Num, Block, _Full} | _] = Blocks, #st{head = {HN, HS}} = S) ->
    Parent = block_parent(Block),
    case Num =:= HN + 1 andalso Parent =:= HS of
        true ->
            do_append_cont(Blocks, S);
        false ->
            case dets:lookup(S#st.hash_tab, {Parent}) of
                [{{Parent}, CA}] when is_integer(CA), CA < HN ->
                    case reorg_rewind(S, CA) of
                        {ok, S1} ->
                            case Num =:= CA + 1 of
                                true -> do_append_cont(Blocks, S1);
                                false -> {{reorg, CA}, S1}
                            end;
                        {error, R} ->
                            {{error, R}, S}
                    end;
                _ ->
                    {{missing_parent, Parent}, S}
            end
    end.

%% Continue a batch assuming the first entry `just linked' to the head.
do_append_cont([], S) ->
    {ok, S};
do_append_cont([{Num, Block, Full} | Rest], #st{head = undefined} = S) ->
    Hash = block_hash(Block),
    do_append_cont(Rest, set_low(insert(S, Num, Hash, Block, Full), Num));
do_append_cont([{Num, Block, Full} | Rest], #st{head = {HN, HS}} = S) ->
    Hash = block_hash(Block),
    Parent = block_parent(Block),
    case Num =:= HN + 1 andalso Parent =:= HS of
        true ->
            do_append_cont(Rest, insert(S, Num, Hash, Block, Full));
        false ->
            case dets:lookup(S#st.hash_tab, {Parent}) of
                [{{Parent}, CA}] when is_integer(CA), CA < HN ->
                    case reorg_rewind(S, CA) of
                        {ok, S1} ->
                            case Num =:= CA + 1 of
                                true -> do_append_cont(Rest, insert(S1, Num, Hash, Block, Full));
                                false -> {{reorg, CA}, S1}
                            end;
                        {error, R} ->
                            {{error, R}, S}
                    end;
                _ ->
                    {{missing_parent, Parent}, S}
            end
    end.

%% Verify each block before storing it, in two independent steps.
%%
%% 1. **Integrity** -- `eth_header:verify/1' recomputes `Keccak256(RLP(header))' and
%%    compares it with the hash the block claims. This answers "were these bytes the
%%    bytes that were signed".
%% 2. **Validity** -- `eth_block_validator:validate/2' checks the header against the
%%    rules in `execution-specs`' `validate_header/2` and `check_gas_limit/2`.
%%    This answers "should this block exist at all".
%%
%% **The second step is not what `VERIFY_HEADERS=false' turns off.** That switch is
%% named for hash recomputation, which is what it did and all it did until this pass,
%% and turning it off now disables a *consensus* check along with a performance
%% optimisation. It is left gating both because a header rule that an operator can
%% switch off is not a rule, and **the operator-facing name now understates what it
%% does** -- recorded in `TASKS.md` rather than silently reinterpreted, because
%% renaming an environment variable is an interface change and this is not the pass
%% for it.
%%

%% **One arity, not two.** `verify_blocks/2' existed to short-circuit on
%% `S#st.verify' before this pass; with the parent threaded through there is a single
%% three-argument form, and leaving a two-argument clause that nothing called would be a
%% second entry point reading blocks with no parent to check them against.
verify_blocks(Blocks, false, _S) -> {ok, Blocks};
verify_blocks([], _Verify, _S) -> {ok, []};
verify_blocks(Blocks, true, S) ->
    verify_blocks(Blocks, true, S, undefined).
verify_blocks([], _Verify, _S, _BatchParent) ->
    {ok, []};
verify_blocks([{Num, Block, Full} | Rest], true, S, BatchParent) ->
    case eth_header:verify(Block) of
        {ok, H} ->
            Normalised = Block#{<<"hash">> => H},
            Parent = parent_for(Normalised, BatchParent, S),
            case eth_block_validator:validate(Parent, Normalised) of
                ok ->
                    case verify_blocks(Rest, true, S, Normalised) of
                        {ok, RestV} -> {ok, [{Num, Normalised, Full} | RestV]};
                        {error, _} = E -> E
                    end;
                {error, Reason} ->
                    {error, {invalid_header, Num, Reason}}
            end;
        {error, Reason} ->
            {error, {bad_block, Num, Reason}}
    end.

%% **The parent is the block its `parentHash\' names. The head is not it.**
%%
%% This pass used to be seeded with `head_block(S)\' and then thread each block into the
%% next. That is right for a contiguous append and **wrong for every other batch**: a reorg
%% hands it a fork that starts below the head. `eth_chain_tests:reorg_test\' appends blocks
%% 3..11 while the head is block 8, and block 3 was validated against block 8 --
%% `{invalid_header, 3, {timestamp_not_after_parent, 1003, 1008}}\', block 3\'s own second
%% against block 8\'s. **The fixture was right and the check was reading the wrong
%% parent**: the fork links to block 2, whose timestamp is 1002. A contiguous batch never
%% showed it, because there the head *is* the parent -- which is why it took a reorg test
%% to find, and why passing on the happy path was never evidence about this line.
%%
%% Two candidates, and the block\'s own `parentHash\' decides between them: the previous
%% block of *this batch*, which is not in the store yet (`do_append/2\' runs after this
%% pass), or a block the store holds. A genesis block names no parent, so neither matches
%% and it is checked against `undefined\' -- the one case where the parent-relative rules
%% cannot run.
%%
%% **Both forms are the hex string this store uses.** `eth_header:verify/1\' answers the
%% `0x...\' form and `hash_tab\' is keyed on it (`do_append/2\' compares a block\'s
%% `parentHash\' against the head hash directly), so the comparison is against `verify/1\'
%% and not `hash/1\', whose answer is 32 raw bytes and can never equal a `parentHash\'.
%%
%% **The comparison in the second clause is unreachable through `append/2', and it is
%% kept anyway.** An injection that deletes it passes the whole suite -- there is no test
%% for it, because the shape it guards cannot be built: a batch that starts below the head
%% rewinds to the common ancestor and drops everything above it, so the second block of a
%% batch can only ever link to the first. The first version of a test here asked for one
%% and got `{missing_parent, _}', which is the store catching the gap **before** the
%% validator is reached. **A gap is caught by `missing_parent', not by this check**, and
%% that is worth stating rather than leaving a plausible-looking test to imply otherwise.
%%
%% So this is defensive, in the sense AGENTS.md means for `eth_evm:run/5'\'s refund cap: a
%% default that is right for every caller that exists. It is kept because it is the rule,
%% because deleting it would make the function depend on a reachability argument that lives
%% in `do_append/2' rather than here, and because **an assertion that a branch is
%% unreachable is itself an assertion someone can check** -- the injection above is how.
%%
%% **The general form is the one this repository keeps meeting: a value looked up once and
%% carried, where the thing it stands for is named per item.**
parent_for(Block, undefined, S) ->
    stored_parent(Block, S);
parent_for(Block, BatchParent, S) ->
    case maps:get(<<"parentHash">>, Block, undefined) of
        Claimed when is_binary(Claimed) ->
            case eth_header:verify(BatchParent) of
                {ok, ParentHash} ->
                    case Claimed =:= ParentHash of
                        true -> BatchParent;
                        false -> stored_parent(Block, S)
                    end;
                {error, _} ->
                    stored_parent(Block, S)
            end;
        _ ->
            undefined
    end.

stored_parent(Block, S) ->
    case maps:get(<<"parentHash">>, Block, undefined) of
        Claimed when is_binary(Claimed) ->
            case dets:lookup(S#st.hash_tab, {Claimed}) of
                [{{Claimed}, N}] ->
                    case dets:lookup(S#st.num_tab, {N}) of
                        [{{N}, {_H, Parent, _Full}}] -> Parent;
                        [] -> undefined
                    end;
                [] ->
                    undefined
            end;
        _ ->
            undefined
    end.

%% The current head's stored header, or `undefined' for an empty store.
%%
%% `hash_tab' maps a hash to a *number*, so the block itself comes from `num_tab' --
%% which is the point: the parent handed to the validator is the one **this node
%% stored**, not one an upstream supplied alongside the child.
%%
%% **A pure function of the state, not a `gen_server:call'.** The first version read
%% the head with `gen_server:call(?MODULE, head_block)' from inside `handle_call', and
%% the suite died with
%%
%%     {calling_self, {gen_server, call, [eth_chain, head_block]}}
%%
%% cancelled at the third test -- `gen:call' refuses a call from the server to itself,
%% so the parent lookup could not be a round trip. The state is already in hand at the
%% call site; going out to ask for it was the whole bug.


below_finality(#st{finalized = undefined}, _N) -> false;
below_finality(#st{finalized = F}, N) -> N < F.

reorg_rewind(S, CA) ->
    case below_finality(S, CA) of
        true -> {error, {below_finality, S#st.finalized}};
        false -> {ok, rewind_to(S, CA)}
    end.

insert(S, Num, Hash, Block, Full) ->
    %% If a different block already occupies Num, retire its stale indexes.
    case dets:lookup(S#st.num_tab, {Num}) of
        [{{Num}, {OldHash, OldBlock, _}}] when OldHash =/= Hash ->
            ok = dets:delete(S#st.hash_tab, {{OldHash}}),
            ok = unindex_txs(S, OldBlock);
        _ ->
            ok
    end,
    ok = dets:insert(S#st.num_tab, {{Num}, {Hash, Block, Full}}),
    ok = dets:insert(S#st.hash_tab, {{Hash}, Num}),
    ok = dets:insert(S#st.meta_tab, {head, {Num, Hash}}),
    ok = index_txs(S, Num, Block, Full),
    ok = dets:sync(S#st.num_tab),
    ok = dets:sync(S#st.hash_tab),
    ok = dets:sync(S#st.meta_tab),
    S#st{head = {Num, Hash}}.

%% ---------------------------------------------------------------------------
%% Retention / pruning
%% ---------------------------------------------------------------------------

%% Delete blocks below the retention floor, incrementally from the `low'
%% watermark. A no-op with no head. Returns the (possibly advanced) state.
prune(#st{head = undefined} = S) ->
    S;
prune(#st{head = {HN, _}, low = Low} = S) ->
    Below = prune_below(HN, S),
    case Below > Low of
        true -> delete_range(S, Low, min(Below, Low + ?PRUNE_BATCH), S#st.finalized);
        false -> S
    end.

%% Everything strictly below this number is pruned, except the finalized block
%% itself (kept so `rewind' to the checkpoint stays possible). Keeps the head
%% plus the most recent `retention' blocks; R is clamped >= max reorg depth at
%% start-up, so a rewind target is never pruned.
prune_below(HN, #st{retention = R}) ->
    max(HN - R + 1, 0).

delete_range(S, From, To, Skip) when From < To ->
    lists:foreach(
        fun(N) when N =:= Skip ->
                ok;
           (N) ->
                case dets:lookup(S#st.num_tab, {N}) of
                    [{{N}, {H, Block, _}}] ->
                        ok = dets:delete(S#st.hash_tab, {{H}}),
                        ok = dets:delete(S#st.num_tab, {N}),
                        ok = dets:delete(S#st.receipts_tab, {N}),
                        ok = unindex_txs(S, Block);
                    [] ->
                        ok
                end
        end, lists:seq(From, To - 1)),
    set_low(S, To);
delete_range(S, _From, _To, _Skip) ->
    S.

set_low(S, N) ->
    ok = dets:insert(S#st.meta_tab, {low, N}),
    S#st{low = N}.

rewind_to(#st{head = undefined} = S, _CA) ->
    S;
rewind_to(#st{head = {HN, _}} = S, CA) when HN > CA ->
    lists:foreach(
        fun(K) ->
            case dets:lookup(S#st.num_tab, {K}) of
                [{{K}, {H, Block, _}}] ->
                    ok = dets:delete(S#st.num_tab, {K}),
                    ok = dets:delete(S#st.hash_tab, {{H}}),
                    ok = dets:delete(S#st.receipts_tab, {K}),
                    ok = unindex_txs(S, Block);
                [] ->
                    ok
            end
        end, lists:seq(CA + 1, HN)),
    Head0 = case dets:lookup(S#st.num_tab, {CA}) of
                [{{CA}, {H, _, _}}] -> {CA, H};
                [] -> undefined
            end,
    case Head0 of
        undefined -> ok = dets:delete(S#st.meta_tab, head);
        {N2, H2} -> ok = dets:insert(S#st.meta_tab, {head, {N2, H2}})
    end,
    ok = dets:sync(S#st.meta_tab),
    S#st{head = Head0};
rewind_to(S, _CA) ->
    S.

lookup_canonical(S, N) ->
    case dets:lookup(S#st.num_tab, {N}) of
        [{{N}, {Hash, _, _}}] -> Hash;
        [] -> undefined
    end.

index_txs(S, Num, Block, true) ->
    case maps:get(<<"transactions">>, Block, []) of
        Txs when is_list(Txs) ->
            lists:foreach(fun(Tx) ->
                case Tx of
                    #{<<"hash">> := H} when is_binary(H) ->
                        dets:insert(S#st.tx_tab, {{H}, Num});
                    _ ->
                        ok
                end
            end, Txs),
            ok;
        _ ->
            ok
    end;
index_txs(_, _, _, _) ->
    ok.

unindex_txs(S, Block) ->
    case maps:get(<<"transactions">>, Block, []) of
        Txs when is_list(Txs) ->
            lists:foreach(fun(Tx) ->
                case Tx of
                    #{<<"hash">> := H} when is_binary(H) ->
                        dets:delete(S#st.tx_tab, {{H}});
                    _ ->
                        ok
                end
            end, Txs),
            ok;
        _ ->
            ok
    end.

block_hash(Block) -> maps:get(<<"hash">>, Block, <<>>).
block_parent(Block) -> maps:get(<<"parentHash">>, Block, <<>>).

%% ---------------------------------------------------------------------------
%% Consistency check: validate that head hash matches num_tab/hash_tab.
%% Called at startup after dets:open_file with repair=force.
%% ---------------------------------------------------------------------------

check_consistency(NumTab, HashTab, _MetaTab, Head) ->
    case Head of
        undefined -> ok;
        {N, H} ->
            case dets:lookup(NumTab, {N}) of
                [{{N}, {H2, _, _}}] when H2 =:= H ->
                    case dets:lookup(HashTab, {{H}}) of
                        [{{H}, N}] -> ok;
                        _ -> logger:warning("etherlang: chain hash_tab mismatch at ~p", [N]), ok
                    end;
                _ -> logger:warning("etherlang: chain num_tab mismatch at ~p", [N]), ok
            end
    end.

%% ---------------------------------------------------------------------------
%% Gas used query
%% ---------------------------------------------------------------------------
