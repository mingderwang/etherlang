-module(eth_eth).

%% eth capability (eth/66-68 message shapes): Status exchange, serving
%% GetBlockHeaders from the local chain, and verifying received header
%% chains by parent linkage.
%%
%% Scope: Status + GetBlockHeaders/BlockHeaders only. Bodies, receipts,
%% pooled transactions, and snap sync are later increments.
%%
%% ForkID policy: network ID and genesis are enforced strictly; the fork
%% hash/next is accepted leniently (logged) and sent as zeros. Strict
%% EIP-2124 ForkID computation against the Sepolia fork schedule is a
%% follow-up; until then strict geth peers may drop our Status.

-export([caps/0, negotiate/1]).
-export([status_data/0, status_data/1, encode_status/1, decode_status/1,
         decode_status_bin/1, check_status/2]).
-export([serve_headers/5, verify_chain/2, verify_chain/3]).
-export([msg_status/1, msg_get_headers/1, msg_headers/1,
         msg_get_bodies/1, msg_bodies/1, msg_get_receipts/1, msg_receipts/1]).
-export([encode_get_headers/4, decode_get_headers_bin/1, decode_headers_bin/1]).
-export([encode_get_bodies/1, decode_get_bodies_bin/1, decode_bodies_bin/1,
         serve_bodies/2, bodies_tx_root/1, verify_bodies/2]).
-export([encode_get_receipts/1, decode_get_receipts_bin/1,
         decode_receipts_bin/1, serve_receipts/2, verify_receipts/2]).
-export([assemble_blocks/2]).
-export([network_id/0, genesis_hash/0]).

-define(ETH_VERSION, 68).
-define(NETWORK_ID, 11155111).
-define(MAX_HEADERS, 192).
%% Sepolia genesis (params.SepoliaGenesisHash in go-ethereum).
-define(GENESIS_HEX, <<"0x25a5cc106eea7138acab33231d7160d69cb777ee0c2c553fcddf5138993e6dd9">>).
%% Compat fallback TD (see eth_rpc_handler SEPOLIA_TTD_HEX).
-define(FALLBACK_TD, 17000000000000000).

network_id() -> ?NETWORK_ID.
genesis_hash() -> hex_to_bin(?GENESIS_HEX).

caps() -> [{"eth", ?ETH_VERSION}].

%% Negotiate against the peer's Hello caps [{Name, Version}]. Single shared
%% capability assumption: eth sits at base 16 (right after p2p).
negotiate(PeerCaps) ->
    case [V || {N, V} <- PeerCaps, N =:= <<"eth">> orelse N =:= "eth"] of
        [] ->
            {error, no_eth};
        Vs ->
            Vp = lists:max([to_int(V) || V <- Vs]),
            case Vp >= 66 of
                true -> {ok, #{version => min(?ETH_VERSION, Vp), base => 16}};
                false -> {error, {eth_too_old, Vp}}
            end
    end.

msg_status(#{base := B}) -> B + 0.
msg_get_headers(#{base := B}) -> B + 3.
msg_headers(#{base := B}) -> B + 4.
msg_get_bodies(#{base := B}) -> B + 5.
msg_bodies(#{base := B}) -> B + 6.
msg_get_receipts(#{base := B}) -> B + 15.
msg_receipts(#{base := B}) -> B + 16.

%% Local Status from the chain head (Chain default eth_chain) plus the
%% upstream latest totalDifficulty, falling back to the compat constant.
%% ForkID is computed strictly per EIP-2124 (see eth_forkid).
status_data() -> status_data(eth_chain).
status_data(Chain) ->
    case head_info(Chain) of
        {ok, N, H, Time} ->
            {FH, FN} = eth_forkid:current(eth_forkid:genesis(sepolia), eth_forkid:schedule(sepolia), N, Time),
            {ok, #{version => ?ETH_VERSION,
                   network => ?NETWORK_ID,
                   td => total_difficulty(),
                   best => H,
                   best_number => N,
                   head_time => Time,
                   genesis => genesis_hash(),
                   fork_hash => FH,
                   fork_next => FN}};
        {error, no_local_head} ->
            %% Empty store: advertise genesis, exactly like a node that has
            %% not synced anything yet. Peers accept this as a syncing
            %% remote (ForkID rule 2) instead of us failing the handshake.
            GenTime = eth_forkid:genesis_time(sepolia),
            {GH, GN} = eth_forkid:current(eth_forkid:genesis(sepolia),
                                          eth_forkid:schedule(sepolia),
                                          0, GenTime),
            {ok, #{version => ?ETH_VERSION,
                   network => ?NETWORK_ID,
                   td => total_difficulty(),
                   best => genesis_hash(),
                   best_number => 0,
                   head_time => GenTime,
                   genesis => genesis_hash(),
                   fork_hash => GH,
                   fork_next => GN}};
        {error, _} = E ->
            E
    end.

head_info(Chain) ->
    case (try eth_chain:head(Chain) catch _:_ -> undefined end) of
        {N, H} when is_integer(N), is_binary(H) ->
            case (try eth_chain:get_by_number(Chain, N) catch _:_ -> not_found end) of
                {ok, Block, _} ->
                    Time = (try eth_hex:decode(maps:get(<<"timestamp">>, Block))
                            catch _:_ -> 0 end),
                    {ok, N, hex_to_bin(H), Time};
                _ ->
                    {error, no_local_head}
            end;
        _ ->
            {error, no_local_head}
    end.

encode_status(#{version := V, network := Net, td := TD, best := Best,
                genesis := Gen, fork_hash := FH, fork_next := FN}) ->
    [V, Net, TD, Best, Gen, [FH, FN]].

decode_status([V, Net, TD, Best, Gen, [FH, FN] | _]) ->
    try
        {ok, #{version => to_int(V), network => to_int(Net),
               td => to_int(TD), best => to_bin(Best),
               genesis => to_bin(Gen),
               fork_hash => to_bin(FH), fork_next => to_int(FN)}}
    catch _:_ ->
        {error, bad_status}
    end;
decode_status(_) ->
    {error, bad_status}.

%% Decode a wire Status body (snappy already removed by eth_rlpx:recv).
decode_status_bin(Data) when is_binary(Data) ->
    case eth_rlp:decode(Data) of
        {ok, Term, _} -> decode_status(Term);
        {error, _} = E -> E
    end.

%% Check a remote Status against network/genesis plus strict ForkID
%% validation. Local carries our head_number/head_time.
check_status(#{best_number := HN, head_time := HT}, Remote) ->
    check_status(#{head_number => HN, head_time => HT}, Remote);
check_status(#{head_number := HN, head_time := HT} = _Local, Remote) ->
    case Remote of
        #{network := ?NETWORK_ID, genesis := Gen} ->
            case Gen =:= genesis_hash() of
                false ->
                    {error, genesis_mismatch};
                true ->
                    eth_forkid:validate(eth_forkid:genesis(sepolia), eth_forkid:schedule(sepolia), HN, HT,
                                        maps:get(fork_hash, Remote, <<>>),
                                        maps:get(fork_next, Remote, 0))
            end;
        #{network := Net} ->
            {error, {network_mismatch, Net}};
        _ ->
            {error, bad_status}
    end;
check_status(_, _) ->
    {error, bad_status}.

%% GetBlockHeaders body. Ref is {hash, H32} | {number, N};
%% Reverse is boolean.
encode_get_headers({hash, H}, Max, Skip, Reverse) when byte_size(H) =:= 32 ->
    [[H], Max, Skip, rev01(Reverse)];
encode_get_headers({number, N}, Max, Skip, Reverse) when is_integer(N), N >= 0 ->
    [[N], Max, Skip, rev01(Reverse)].

decode_get_headers_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, [[Ref], Max, Skip, Rev | _], _} ->
                {ok, decode_ref(Ref), to_int(Max), to_int(Skip), to_int(Rev) =:= 1};
            _ ->
                {error, bad_headers_req}
        end
    catch _:_ ->
        {error, bad_headers_req}
    end.

%% BlockHeaders body: a list of header RLP lists.
decode_headers_bin(Data) when is_binary(Data) ->
    case eth_rlp:decode(Data) of
        {ok, Headers, _} when is_list(Headers) ->
            case lists:all(fun(H) -> is_list(H) andalso H =/= [] end, Headers) of
                true -> {ok, Headers};
                false -> {error, bad_headers}
            end;
        _ ->
            {error, bad_headers}
    end.

rev01(true) -> 1;
rev01(_) -> 0.

decode_ref(B) when byte_size(B) =:= 32 -> {hash, B};
decode_ref(B) -> {number, to_int(B)}.

%% --- bodies ------------------------------------------------------------

encode_get_bodies(Hashes) when is_list(Hashes) -> [Hashes].

decode_get_bodies_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, [Hashes], _} when is_list(Hashes) ->
                case lists:all(fun(H) -> is_binary(H) andalso byte_size(H) =:= 32 end,
                               Hashes) of
                    true -> {ok, Hashes};
                    false -> {error, bad_bodies_req}
                end;
            _ ->
                {error, bad_bodies_req}
        end
    catch _:_ ->
        {error, bad_bodies_req}
    end.

%% Serve bodies from Chain: [{ok, [TxsTerms, UnclesTerms]}] per hash, with
%% [] for unknown, header-only, or unencodable bodies (geth-compatible).
serve_bodies(Chain, Hashes) ->
    {ok, [serve_body(Chain, H) || H <- Hashes]}.

serve_body(Chain, H) ->
    Hex = <<"0x", (string:lowercase(binary:encode_hex(H)))/binary>>,
    case (try eth_chain:get_by_hash(Chain, Hex) catch _:_ -> not_found end) of
        {ok, Block, true} ->
            case maps:get(<<"transactions">>, Block, bad) of
                [] ->
                    [[], uncles_terms(Block)];
                [First | _] = Txs when is_map(First) ->
                    case body_terms(Txs) of
                        {ok, Terms} -> [Terms, uncles_terms(Block)];
                        {error, _} -> []
                    end;
                _ ->
                    []
            end;
        _ ->
            []
    end.

body_terms(Txs) ->
    try
        {ok, [tx_term(Tx) || Tx <- Txs]}
    catch _:_ ->
        {error, bad_tx}
    end.

%% Legacy txs decode back to list terms; typed stay as opaque binaries.
tx_term(Tx) ->
    {ok, Enc} = eth_tx:to_rlp(Tx),
    case Enc of
        <<16#01, _/binary>> -> Enc;
        <<16#02, _/binary>> -> Enc;
        _ ->
            {ok, Term, <<>>} = eth_rlp:decode(Enc),
            Term
    end.

uncles_terms(Block) ->
    case maps:get(<<"uncles">>, Block, []) of
        [] -> [];
        Uncles when is_list(Uncles) ->
            Terms = lists:filtermap(fun(U) ->
                case (try eth_header:to_rlp_list(U) catch _:_ -> error end) of
                    {ok, T} -> {true, T};
                    _ -> false
                end
            end, Uncles),
            Terms;
        _ -> []
    end.

%% Decode a BlockBodies body: list of [Txs, Uncles] with txs as binaries
%% (typed) or lists (legacy).
decode_bodies_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, Bodies, _} when is_list(Bodies) ->
                case lists:all(fun wellformed_body/1, Bodies) of
                    true -> {ok, Bodies};
                    false -> {error, bad_bodies}
                end;
            _ ->
                {error, bad_bodies}
        end
    catch _:_ ->
        {error, bad_bodies}
    end.

wellformed_body([Txs, Uncles]) when is_list(Txs), is_list(Uncles) ->
    lists:all(fun(T) ->
        (is_binary(T) andalso byte_size(T) > 1) orelse
        (is_list(T) andalso T =/= [])
    end, Txs);
wellformed_body(_) ->
    false.

%% Transaction trie root of one wire body [Txs, _Uncles].
bodies_tx_root([Txs, _]) ->
    try
        Pairs = lists:map(fun({T, I}) ->
            {eth_rlp:encode(I), tx_bytes(T)}
        end, lists:zip(Txs, lists:seq(0, length(Txs) - 1))),
        {ok, eth_trie:root(Pairs)}
    catch _:_ ->
        {error, bad_body}
    end.

tx_bytes(B) when is_binary(B) -> B;
tx_bytes(L) when is_list(L) -> eth_rlp:encode(L).

%% Verify bodies against header RLP lists: same count and each tx-root
%% matches the header's transactionsRoot (field index 4).
verify_bodies(Headers, Bodies) when length(Headers) =:= length(Bodies) ->
    try
        lists:foreach(fun({H, B}) ->
            {ok, Root} = bodies_tx_root(B),
            true = tx_root_of(H) =:= Root
        end, lists:zip(Headers, Bodies)),
        ok
    catch _:_ ->
        {error, body_mismatch}
    end;
verify_bodies(_, _) ->
    {error, count_mismatch}.

tx_root_of(Header) when is_list(Header) ->
    case lists:nth(5, Header) of
        R when byte_size(R) =:= 32 -> R;
        _ -> error
    end.

%% Assemble chain-store entries from wire headers + bodies:
%% [{Num, BlockMap, true}]. Verifies body roots against the headers, so a
%% mismatch fails before anything reaches the chain.
assemble_blocks(Headers, Bodies) ->
    case verify_bodies(Headers, Bodies) of
        ok -> assemble_each(Headers, Bodies, []);
        {error, _} = E -> E
    end.

assemble_each([], [], Acc) -> {ok, lists:reverse(Acc)};
assemble_each([H | Hs], [B | Bs], Acc) ->
    case assemble_block(H, B) of
        {ok, Entry} -> assemble_each(Hs, Bs, [Entry | Acc]);
        {error, _} = E -> E
    end;
assemble_each(_, _, _) ->
    {error, count_mismatch}.

assemble_block(HeaderRLP, [TxsTerms, UnclesTerms]) ->
    try
        {ok, HMap} = eth_header:from_rlp(HeaderRLP),
        Hash = eth_keccak:hash(eth_rlp:encode(HeaderRLP)),
        Txs = [begin {ok, M} = eth_tx:from_rlp(tx_bytes(T)), M end
               || T <- TxsTerms],
        Uncles = [begin {ok, M} = eth_header:from_rlp(U), M end
                  || U <- UnclesTerms],
        Num = eth_header:number(HMap#{<<"hash">> => hex0x(Hash)}),
        true = is_integer(Num),
        Block = (HMap#{<<"hash">> => hex0x(Hash),
                       <<"transactions">> => Txs,
                       <<"uncles">> => Uncles}),
        {ok, {Num, Block, true}}
    catch _:_ ->
        {error, bad_block}
    end.

hex0x(Bin) ->
    <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

%% --- receipts ----------------------------------------------------------
%% eth/68 GetReceipts [hashes] / Receipts [[receipt...]...] (0x0f / 0x10).
%% Receipts are RLP terms (binary for typed, list for legacy), like bodies.

encode_get_receipts(Hashes) when is_list(Hashes) -> [Hashes].

decode_get_receipts_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, [Hashes], _} when is_list(Hashes) ->
                case lists:all(fun(H) -> is_binary(H) andalso byte_size(H) =:= 32 end,
                               Hashes) of
                    true -> {ok, Hashes};
                    false -> {error, bad_receipts_req}
                end;
            _ ->
                {error, bad_receipts_req}
        end
    catch _:_ ->
        {error, bad_receipts_req}
    end.

%% Serve from the receipts store: [ReceiptTerms] per hash, [] when unknown.
serve_receipts(Chain, Hashes) ->
    {ok, [serve_receipt(Chain, H) || H <- Hashes]}.

serve_receipt(Chain, H) ->
    Hex = <<"0x", (string:lowercase(binary:encode_hex(H)))/binary>>,
    N = case (try eth_chain:get_by_hash(Chain, Hex) catch _:_ -> not_found end) of
            {ok, Block, _} ->
                eth_header:number(Block);
            _ ->
                undefined
        end,
    case N of
        N when is_integer(N) ->
            case (try eth_chain:receipts(Chain, N) catch _:_ -> not_found end) of
                {ok, Receipts} ->
                    [receipt_term(R) || R <- Receipts];
                _ ->
                    []
            end;
        _ ->
            []
    end.

receipt_term(R) when is_map(R) ->
    {ok, Enc} = eth_receipt:to_rlp(R),
    case Enc of
        <<T, _/binary>> when T =:= 16#01; T =:= 16#02; T =:= 16#03 -> Enc;
        _ ->
            {ok, Term, <<>>} = eth_rlp:decode(Enc),
            Term
    end;
receipt_term(B) when is_binary(B) ->
    B.

decode_receipts_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, Lists, _} when is_list(Lists) ->
                case lists:all(fun wellformed_receipts/1, Lists) of
                    true -> {ok, Lists};
                    false -> {error, bad_receipts}
                end;
            _ ->
                {error, bad_receipts}
        end
    catch _:_ ->
        {error, bad_receipts}
    end.

wellformed_receipts(Rs) when is_list(Rs) ->
    lists:all(fun(R) ->
        (is_binary(R) andalso byte_size(R) > 1) orelse
        (is_list(R) andalso R =/= [])
    end, Rs);
wellformed_receipts(_) ->
    false.

%% Receipt trie root of one wire receipt list.
receipts_root(Rs) ->
    try
        Pairs = lists:map(fun({R, I}) ->
            {eth_rlp:encode(I), receipt_bytes(R)}
        end, lists:zip(Rs, lists:seq(0, length(Rs) - 1))),
        {ok, eth_trie:root(Pairs)}
    catch _:_ ->
        {error, bad_receipts}
    end.

receipt_bytes(B) when is_binary(B) -> B;
receipt_bytes(L) when is_list(L) -> eth_rlp:encode(L).

%% Verify receipt lists against header RLP lists (count + receiptsRoot at
%% field index 5).
verify_receipts(Headers, AllReceipts) when length(Headers) =:= length(AllReceipts) ->
    try
        lists:foreach(fun({H, Rs}) ->
            {ok, Root} = receipts_root(Rs),
            true = receipts_root_of(H) =:= Root
        end, lists:zip(Headers, AllReceipts)),
        ok
    catch _:_ ->
        {error, receipts_mismatch}
    end;
verify_receipts(_, _) ->
    {error, count_mismatch}.

receipts_root_of(Header) when is_list(Header) ->
    case lists:nth(6, Header) of
        R when byte_size(R) =:= 32 -> R;
        _ -> error
    end.
%% Returns {ok, [RLPHeaderList]} (possibly shorter than asked when the store
%% cannot cover the range; at most MAX_HEADERS).
serve_headers(Chain, BlockRef, Max, Skip, Reverse) ->
    Max1 = min(to_int(Max), ?MAX_HEADERS),
    case Max1 > 0 of
        false ->
            {ok, []};
        true ->
            case start_number(Chain, BlockRef) of
                {ok, Start} -> walk(Chain, Start, Max1, to_int(Skip), Reverse, []);
                {error, _} = E -> E
            end
    end.

%% Verify parent linkage of a received header chain. Order=true means the
%% list runs low->high (reverse=false fetch); false means high->low.
%% Skip>0 responses are not adjacency-linked (intermediate headers were
%% skipped), so only well-formedness is checked then.
verify_chain(Headers, Order) -> verify_chain(Headers, Order, 0).
verify_chain(Headers, _Order, Skip) when Skip > 0 ->
    case lists:all(fun wellformed/1, Headers) of
        true -> ok;
        false -> {error, malformed_header}
    end;
verify_chain([], _, _) -> ok;
verify_chain([_], _, _) -> ok;
verify_chain([A, B | Rest], true, 0) ->
    case parent_of(B) =:= hash_of(A) of
        true -> verify_chain([B | Rest], true, 0);
        false -> {error, broken_linkage}
    end;
verify_chain([A, B | Rest], false, 0) ->
    case parent_of(A) =:= hash_of(B) of
        true -> verify_chain([B | Rest], false, 0);
        false -> {error, broken_linkage}
    end.

wellformed(H) when is_list(H), H =/= [] ->
    is_binary(parent_of(H));
wellformed(_) ->
    false.

%% ---------------------------------------------------------------------------

total_difficulty() ->
    case (try eth_rpc_client:call(<<"eth_getBlockByNumber">>, [<<"latest">>, false])
          catch _:_ -> error end) of
        {ok, #{<<"totalDifficulty">> := TD}} ->
            try eth_hex:decode(TD) catch _:_ -> ?FALLBACK_TD end;
        _ ->
            ?FALLBACK_TD
    end.

start_number(Chain, {hash, H}) when byte_size(H) =:= 32 ->
    Hex = <<"0x", (string:lowercase(binary:encode_hex(H)))/binary>>,
    case (try eth_chain:get_by_hash(Chain, Hex) catch _:_ -> not_found end) of
        {ok, Block, _} ->
            case eth_header:number(Block) of
                N when is_integer(N) -> {ok, N};
                _ -> {error, unknown_hash}
            end;
        _ ->
            %% Hash store keys may differ in case; scan canonical numbers.
            find_by_hash(Chain, H)
    end;
start_number(_Chain, {number, N}) when is_integer(N), N >= 0 ->
    {ok, N};
start_number(_, _) ->
    {error, bad_ref}.

%% Fallback hash lookup by scanning canonical numbers (hash_tab keys are
%% hex strings whose case may vary).
find_by_hash(Chain, H) ->
    Highest = (try eth_chain:highest(Chain) catch _:_ -> -1 end),
    find_by_hash(Chain, H, Highest).

find_by_hash(_Chain, _H, N) when N < 0 -> {error, unknown_hash};
find_by_hash(Chain, H, N) ->
    case (try eth_chain:canonical_hash(Chain, N) catch _:_ -> undefined end) of
        Hex when is_binary(Hex) ->
            case hex_to_bin(Hex) of
                H -> {ok, N};
                _ -> find_by_hash(Chain, H, N - 1)
            end;
        _ ->
            {error, unknown_hash}
    end.

walk(_Chain, _Num, 0, _Skip, _Rev, Acc) ->
    {ok, lists:reverse(Acc)};
walk(Chain, Num, Left, Skip, Rev, Acc) when Num >= 0 ->
    case (try eth_chain:get_by_number(Chain, Num) catch _:_ -> not_found end) of
        {ok, Block, _} ->
            case eth_header:to_rlp_list(Block) of
                {ok, Term} ->
                    Next = case Rev of
                               true -> Num - (Skip + 1);
                               _ -> Num + (Skip + 1)
                           end,
                    walk(Chain, Next, Left - 1, Skip, Rev, [Term | Acc]);
                {error, _} ->
                    {ok, lists:reverse(Acc)}
            end;
        _ ->
            {ok, lists:reverse(Acc)}
    end;
walk(_Chain, _Num, _Left, _Skip, _Rev, Acc) ->
    {ok, lists:reverse(Acc)}.

parent_of([Parent | _]) when byte_size(Parent) =:= 32 -> Parent;
parent_of(_) -> error.

hash_of(Term) when is_list(Term) -> eth_keccak:hash(eth_rlp:encode(Term));
hash_of(_) -> error.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B), byte_size(B) =:= 0 -> 0;
to_int(B) when is_binary(B) -> binary:decode_unsigned(B);
to_int(_) -> 0.

to_bin(B) when is_binary(B) -> B;
to_bin(I) when is_integer(I) -> binary:encode_unsigned(I);
to_bin(_) -> <<>>.

hex_to_bin(Hex) when is_binary(Hex) ->
    No0x = case Hex of
               <<"0x", Rest/binary>> -> Rest;
               <<"0X", Rest/binary>> -> Rest;
               _ -> Hex
           end,
    try binary:decode_hex(No0x) catch _:_ -> <<>> end.
