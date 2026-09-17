-module(eth_test_util).

-export([start_apps/0, free_port/0, tmp_dir/1, tmp_dir/0, bin_to_hex/1,
         wait_until/3, block/3, make_blocks/4]).

start_apps() ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    ok.

free_port() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    ok = gen_tcp:close(L),
    Port.

tmp_dir() -> tmp_dir(erlang:unique_integer([positive])).

tmp_dir(Prefix) ->
    D = filename:join("/tmp", "etherlang_test_" ++ integer_to_list(Prefix)
                           ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(D, "x")),
    D.

bin_to_hex(Bin) ->
    << <<(hex_digit(H)), (hex_digit(L))>> || <<H:4, L:4>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

wait_until(Fun, SleepMs, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_until_n(Fun, SleepMs, Deadline).

wait_until_n(Fun, SleepMs, Deadline) ->
    case catch Fun() of
        true ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error(wait_timeout);
                false ->
                    timer:sleep(SleepMs),
                    wait_until_n(Fun, SleepMs, Deadline)
            end
    end.

%% ---------------------------------------------------------------------------
%% Deterministic synthetic blocks (used by the mock node and chain tests)
%% ---------------------------------------------------------------------------

block_hash(Num, Parent, Salt) ->
    Hash = crypto:hash(sha256, term_to_binary({Num, Parent, Salt})),
    <<"0x", (bin_to_hex(Hash))/binary>>.

tx_hash(Num, Idx) ->
    Hash = crypto:hash(sha256, term_to_binary({tx, Num, Idx})),
    <<"0x", (bin_to_hex(Hash))/binary>>.

block(Num, Parent, Salt) ->
    H = block_hash(Num, Parent, Salt),
    #{<<"number">> => eth_hex:encode_int(Num),
      <<"hash">> => H,
      <<"parentHash">> => Parent,
      <<"timestamp">> => eth_hex:encode_int(1000 + Num),
      <<"gasLimit">> => eth_hex:encode_int(30000000),
      <<"gasUsed">> => eth_hex:encode_int(0),
      <<"difficulty">> => eth_hex:encode_int(0),
      <<"totalDifficulty">> => eth_hex:encode_int(0),
      <<"miner">> => <<"0x0000000000000000000000000000000000000000">>,
      <<"nonce">> => <<"0x0000000000000000">>,
      <<"size">> => eth_hex:encode_int(600),
      <<"extraData">> => <<"0x">>,
      <<"stateRoot">> => <<"0x0000000000000000000000000000000000000000000000000000000000000000">>,
      <<"receiptsRoot">> => <<"0x0000000000000000000000000000000000000000000000000000000000000000">>,
      <<"logsBloom">> => <<"0x">>,
      <<"transactions">> =>
          [#{<<"hash">> => tx_hash(Num, 0),
             <<"blockHash">> => H,
             <<"blockNumber">> => eth_hex:encode_int(Num),
             <<"from">> => <<"0x1000000000000000000000000000000000000001">>,
             <<"to">> => <<"0x1000000000000000000000000000000000000002">>,
             <<"gas">> => eth_hex:encode_int(21000),
             <<"gasPrice">> => eth_hex:encode_int(1),
             <<"input">> => <<"0x">>,
             <<"nonce">> => eth_hex:encode_int(0),
             <<"transactionIndex">> => eth_hex:encode_int(0),
             <<"value">> => eth_hex:encode_int(0),
             <<"v">> => <<"0x1">>,
             <<"r">> => <<"0x0">>,
             <<"s">> => <<"0x0">>},
           #{<<"hash">> => tx_hash(Num, 1),
             <<"blockHash">> => H,
             <<"blockNumber">> => eth_hex:encode_int(Num),
             <<"from">> => <<"0x1000000000000000000000000000000000000001">>,
             <<"to">> => <<"0x1000000000000000000000000000000000000003">>,
             <<"gas">> => eth_hex:encode_int(21000),
             <<"gasPrice">> => eth_hex:encode_int(1),
             <<"input">> => <<"0x">>,
             <<"nonce">> => eth_hex:encode_int(1),
             <<"transactionIndex">> => eth_hex:encode_int(1),
             <<"value">> => eth_hex:encode_int(0),
             <<"v">> => <<"0x1">>,
             <<"r">> => <<"0x0">>,
             <<"s">> => <<"0x0">>}],
      <<"uncles">> => []}.

%% Build Count blocks starting at From, chained to Parent, salted with Salt
%% so different forks sharing a {Num, Parent} produce different hashes.
make_blocks(From, Count, Parent, Salt) ->
    lists:foldl(
        fun(Num, {P, Blocks}) ->
            B = block(Num, P, Salt),
            {maps:get(<<"hash">>, B), Blocks ++ [B]}
        end, {Parent, []}, lists:seq(From, From + Count - 1)).