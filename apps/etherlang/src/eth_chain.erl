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
%% Storage layout (DETS "set" tables):
%%   num_tab   : {{Num}}        -> {Hash, Block, Full}
%%   hash_tab  : {{Hash}}       -> Num
%%   meta_tab  : head           -> {Num, Hash}

-export([start_link/1, start_link/2,
         head/0, head/1,
         append/1, append/2,
         rewind/1, rewind/2,
         get_by_number/1, get_by_number/2,
         get_by_hash/1, get_by_hash/2,
         canonical_hash/1, canonical_hash/2,
         highest/1, has_block/1, has_block/2, size/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {dir, head :: undefined | {integer(), binary()}}).

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
append(Blocks) when is_list(Blocks) -> append(eth_chain, Blocks).
append(Name, Blocks) when is_list(Blocks) ->
    gen_server:call(Name, {append, Blocks}).

%% Rewind the canonical head to Num, discarding everything above it.
rewind(N) -> rewind(eth_chain, N).
rewind(Name, N) -> gen_server:call(Name, {rewind, N}).

get_by_number(N) -> get_by_number(eth_chain, N).
get_by_number(Name, N) -> gen_server:call(Name, {get_by_number, N}).

get_by_hash(H) -> get_by_hash(eth_chain, H).
get_by_hash(Name, H) -> gen_server:call(Name, {get_by_hash, H}).

canonical_hash(N) -> canonical_hash(eth_chain, N).
canonical_hash(Name, N) -> gen_server:call(Name, {canonical_hash, N}).

highest(Name) -> gen_server:call(Name, highest).

has_block(N) -> has_block(eth_chain, N).
has_block(Name, N) ->
    case (catch gen_server:call(Name, {get_by_number, N})) of
        {ok, _, _} -> true;
        _ -> false
    end.

size(Name) -> gen_server:call(Name, size).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

init({Name, Dir}) ->
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    {ok, _} = dets:open_file(num_tab, [{file, filename:join(Dir, "chain.num.dets")},
                                       {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(hash_tab, [{file, filename:join(Dir, "chain.hash.dets")},
                                        {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(meta_tab, [{file, filename:join(Dir, "chain.meta.dets")},
                                        {type, set}, {repair, force}]),
    Head = case dets:lookup(meta_tab, head) of
               [{head, {N, H}}] -> {N, H};
               _ -> undefined
           end,
    _ = Name,
    {ok, #st{dir = Dir, head = Head}}.

handle_call(head, _From, S) ->
    {reply, S#st.head, S};

handle_call(highest, _From, #st{head = undefined} = S) ->
    {reply, -1, S};
handle_call(highest, _From, #st{head = {N, _}} = S) ->
    {reply, N, S};

handle_call(size, _From, S) ->
    {reply, dets:info(num_tab, size), S};

handle_call({canonical_hash, N}, _From, S) ->
    {reply, lookup_canonical(S, N), S};

handle_call({get_by_number, N}, _From, S) ->
    case dets:lookup(num_tab, {N}) of
        [{{N}, {_Hash, Block, Full}}] -> {reply, {ok, Block, Full}, S};
        [] -> {reply, not_found, S}
    end;

handle_call({get_by_hash, H}, _From, S) ->
    case dets:lookup(hash_tab, {H}) of
        [{{H}, N}] ->
            case dets:lookup(num_tab, {N}) of
                [{{N}, {_Hash2, Block, Full}}] -> {reply, {ok, Block, Full}, S};
                [] -> {reply, not_found, S}
            end;
        [] ->
            {reply, not_found, S}
    end;

handle_call({append, Blocks}, _From, S) ->
    {Res, S1} = do_append(Blocks, S),
    {reply, Res, S1};

handle_call({rewind, N}, _From, S) ->
    S1 = rewind_to(S, N),
    {reply, ok, S1};

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) ->
    lists:foreach(fun(T) -> catch dets:close(T) end, [num_tab, hash_tab, meta_tab]),
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
    do_append(Rest, insert(S, Num, Hash, Block, Full));
do_append([{Num, Block, _Full} | _] = Blocks, #st{head = {HN, HS}} = S) ->
    Parent = block_parent(Block),
    case Num =:= HN + 1 andalso Parent =:= HS of
        true ->
            do_append_cont(Blocks, S);
        false ->
            case dets:lookup(hash_tab, {Parent}) of
                [{{Parent}, CA}] when is_integer(CA), CA < HN ->
                    S1 = rewind_to(S, CA),
                    case Num =:= CA + 1 of
                        true ->
                            do_append_cont(Blocks, S1);
                        false ->
                            {{reorg, CA}, S1}
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
    do_append_cont(Rest, insert(S, Num, Hash, Block, Full));
do_append_cont([{Num, Block, Full} | Rest], #st{head = {HN, HS}} = S) ->
    Hash = block_hash(Block),
    Parent = block_parent(Block),
    case Num =:= HN + 1 andalso Parent =:= HS of
        true ->
            do_append_cont(Rest, insert(S, Num, Hash, Block, Full));
        false ->
            case dets:lookup(hash_tab, {Parent}) of
                [{{Parent}, CA}] when is_integer(CA), CA < HN ->
                    S1 = rewind_to(S, CA),
                    case Num =:= CA + 1 of
                        true -> do_append_cont(Rest, insert(S1, Num, Hash, Block, Full));
                        false -> {{reorg, CA}, S1}
                    end;
                _ ->
                    {{missing_parent, Parent}, S}
            end
    end.

insert(S, Num, Hash, Block, Full) ->
    %% If a different block already occupies Num, retire its stale hash index.
    case dets:lookup(num_tab, {Num}) of
        [{{Num}, {OldHash, _, _}}] when OldHash =/= Hash ->
            ok = dets:delete(hash_tab, {{OldHash}});
        _ ->
            ok
    end,
    ok = dets:insert(num_tab, {{Num}, {Hash, Block, Full}}),
    ok = dets:insert(hash_tab, {{Hash}, Num}),
    ok = dets:insert(meta_tab, {head, {Num, Hash}}),
    S#st{head = {Num, Hash}}.

rewind_to(#st{head = undefined} = S, _CA) ->
    S;
rewind_to(#st{head = {HN, _}} = S, CA) when HN > CA ->
    lists:foreach(
        fun(K) ->
            case dets:lookup(num_tab, {K}) of
                [{{K}, {H, _, _}}] ->
                    ok = dets:delete(num_tab, {K}),
                    ok = dets:delete(hash_tab, {{H}});
                [] ->
                    ok
            end
        end, lists:seq(CA + 1, HN)),
    Head0 = case dets:lookup(num_tab, {CA}) of
                [{{CA}, {H, _, _}}] -> {CA, H};
                [] -> undefined
            end,
    case Head0 of
        undefined -> ok = dets:delete(meta_tab, head);
        {N2, H2} -> ok = dets:insert(meta_tab, {head, {N2, H2}})
    end,
    S#st{head = Head0};
rewind_to(S, _CA) ->
    S.

lookup_canonical(_S, N) ->
    case dets:lookup(num_tab, {N}) of
        [{{N}, {Hash, _, _}}] -> Hash;
        [] -> undefined
    end.

block_hash(Block) -> maps:get(<<"hash">>, Block, <<>>).
block_parent(Block) -> maps:get(<<"parentHash">>, Block, <<>>).