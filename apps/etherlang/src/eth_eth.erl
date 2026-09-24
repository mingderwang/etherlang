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
         decode_status_bin/1, check_status/1]).
-export([serve_headers/5, verify_chain/2, verify_chain/3]).
-export([msg_status/1, msg_get_headers/1, msg_headers/1]).
-export([encode_get_headers/4, decode_get_headers_bin/1, decode_headers_bin/1]).
-export([network_id/0, genesis_hash/0]).

-define(ETH_VERSION, 68).
-define(NETWORK_ID, 11155111).
-define(MAX_HEADERS, 192).
%% Sepolia genesis.
-define(GENESIS_HEX, <<"0x25a5cc106eea7138acab3575073b331f03c96d9e154af2551adc1fdf64e2b0a3">>).
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

%% Local Status from the chain head (Chain default eth_chain) plus the
%% upstream latest totalDifficulty, falling back to the compat constant.
status_data() -> status_data(eth_chain).
status_data(Chain) ->
    case (try eth_chain:head(Chain) catch _:_ -> undefined end) of
        {N, H} when is_integer(N) ->
            {ok, #{version => ?ETH_VERSION,
                   network => ?NETWORK_ID,
                   td => total_difficulty(),
                   best => hex_to_bin(H),
                   best_number => N,
                   genesis => genesis_hash(),
                   fork_hash => <<0, 0, 0, 0>>,
                   fork_next => 0}};
        undefined ->
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

check_status(#{network := ?NETWORK_ID, genesis := Gen} = S) ->
    case Gen =:= genesis_hash() of
        true ->
            case {maps:get(fork_hash, S), maps:get(fork_next, S)} of
                {<<0, 0, 0, 0>>, 0} ->
                    ok;
                {FH, FN} ->
                    logger:info("etherlang: peer forkid ~s next ~p (accepted leniently)",
                                [binary:encode_hex(FH), FN]),
                    ok
            end;
        false ->
            {error, genesis_mismatch}
    end;
check_status(#{network := Net}) ->
    {error, {network_mismatch, Net}};
check_status(_) ->
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
