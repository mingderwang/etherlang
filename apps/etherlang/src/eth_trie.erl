-module(eth_trie).

%% Minimal Merkle-Patricia trie root computation (hexary, keccak256) for
%% verifying transaction/receipt roots of fetched bodies. Build-only: no
%% persistence, no proofs. Keys and values are raw binaries (for tx tries:
%% key = RLP(index), value = RLP(tx)).

-export([root/1]).

%% Root of [{Key, Value}]. Empty trie = keccak256(RLP("")).
root([]) ->
    eth_keccak:hash(eth_rlp:encode(<<>>));
root(Pairs) ->
    Tree = lists:foldl(fun({K, V}, T) -> insert(T, nibbles(K), V) end,
                       none, Pairs),
    eth_keccak:hash(encode(Tree)).

%% ---------------------------------------------------------------------------

insert(none, Nibbles, Val) ->
    {leaf, Nibbles, Val};

insert({branch, C, _V}, [], Val) ->
    {branch, C, Val};
insert({branch, C, V}, [H | T], Val) ->
    NewCh = case maps:find(H, C) of
                {ok, Ch} -> insert(Ch, T, Val);
                error -> {leaf, T, Val}
            end,
    {branch, C#{H => NewCh}, V};
insert({leaf, LN, _LV}, N, Val) when N =:= LN ->
    {leaf, LN, Val};
insert({leaf, LN, LV}, N, Val) ->
    L = prefix_len(LN, N),
    CP = lists:sublist(LN, L),
    wrap(CP, merge_rest(lists:nthtail(L, LN), LV, lists:nthtail(L, N), Val));
insert({ext, EN, Child}, N, Val) ->
    L = prefix_len(EN, N),
    case L =:= length(EN) of
        true ->
            {ext, EN, insert(Child, lists:nthtail(L, N), Val)};
        false ->
            CP = lists:sublist(EN, L),
            OR = lists:nthtail(L, EN),
            NR = lists:nthtail(L, N),
            [OH | OT] = OR,
            OldCh = case OT of
                        [] -> Child;
                        _ -> {ext, OT, Child}
                    end,
            Br = case NR of
                     [] ->
                         set_value(set_child(empty_branch(), OH, OldCh), Val);
                     [NH | NT] ->
                         %% Heads differ: L is the maximal common prefix.
                         set_child(set_child(empty_branch(), OH, OldCh),
                                   NH, leaf_or_value(NT, Val))
                 end,
            wrap(CP, Br)
    end.

%% Both remainders after the common prefix; at least one is non-empty
%% (keys differ). Old side is always a leaf value here.
merge_rest([], LV, [], _Val) ->
    {branch, #{}, LV};
merge_rest([], LV, [NH | NT], Val) ->
    add_fresh(set_value(empty_branch(), LV), NH, NT, Val);
merge_rest([OH | OT], LV, [], Val) ->
    add_fresh(set_value(empty_branch(), Val), OH, OT, LV);
merge_rest([OH | OT], LV, [NH | NT], Val) ->
    %% Heads differ: L is the maximal common prefix.
    _ = {OT, NT},
    case OH =:= NH of
        true ->
            %% Defensive: should not happen; nest deeper.
            {branch, #{OH => merge_rest(OT, LV, NT, Val)}, <<>>};
        false ->
            add_fresh(add_fresh(empty_branch(), OH, OT, LV), NH, NT, Val)
    end.

add_fresh(Br, H, NT, Val) -> set_child(Br, H, leaf_or_value(NT, Val)).

%% A key ending below a branch point becomes a leaf with an empty path
%% ([0x20] compact); only a key ending AT a branch node itself becomes the
%% branch value.
leaf_or_value([], Val) -> {leaf, [], Val};
leaf_or_value(T, Val) -> {leaf, T, Val}.

wrap([], Br) -> Br;
wrap(CP, Br) -> {ext, CP, Br}.

empty_branch() -> {branch, #{}, <<>>}.

set_child({branch, C, V}, H, Child) -> {branch, C#{H => Child}, V}.
set_value({branch, C, _}, V) -> {branch, C, V}.

%% --- encoding ------------------------------------------------------------
%%
%% Terms keep inline children as decoded structures (their RLP is spliced
%% raw); only hashed children appear as 32-byte strings. Returning raw
%% bytes here would re-encode them as strings and break the hash.

encode(Node) -> eth_rlp:encode(term(Node)).

term({leaf, N, V}) ->
    [compact(N, true), V];
term({ext, N, Child}) ->
    [compact(N, false), ref(Child)];
term({branch, C, V}) ->
    [ref_at(C, I) || I <- lists:seq(0, 15)] ++ [V].

ref(Child) ->
    E = encode(Child),
    case byte_size(E) < 32 of
        true ->
            {ok, T, <<>>} = eth_rlp:decode(E),
            T;
        false ->
            eth_keccak:hash(E)
    end.

ref_at(C, I) ->
    case maps:find(I, C) of
        {ok, Ch} -> ref(Ch);
        error -> <<>>
    end.

%% Hex-prefix (compact) encoding: flag nibbles pack into bytes with the
%% path nibbles, no extra padding byte.
compact(Nibbles, IsLeaf) ->
    F = case IsLeaf of
            true -> 2;
            false -> 0
        end,
    case Nibbles of
        [H | T] when length(T) rem 2 =:= 0 ->
            pack([F + 1, H | T]);
        _ ->
            pack([F, 0 | Nibbles])
    end.

pack([]) -> <<>>;
pack([A, B | Rest]) ->
    <<((A bsl 4) bor B), (pack(Rest))/binary>>.

%% --- nibbles --------------------------------------------------------------

nibbles(Bin) -> nibbles(Bin, []).
nibbles(<<>>, Acc) -> lists:reverse(Acc);
nibbles(<<H:4, L:4, Rest/binary>>, Acc) -> nibbles(Rest, [L, H | Acc]).

prefix_len(A, B) -> prefix_len(A, B, 0).
prefix_len([H | TA], [H | TB], N) -> prefix_len(TA, TB, N + 1);
prefix_len(_, _, N) -> N.
