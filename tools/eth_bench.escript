#!/usr/bin/env escript
%% -*- erlang -*-
%%! -smp enable +A 16
%%
%% eth_bench: concurrent JSON-RPC load generator against an Ethereum node's HTTP
%% endpoint. Defaults to `eth_call` (the heaviest common RPC, and one our node
%% proxies upstream), but any method/payload can be used via --payload.
%%
%% Usage:
%%   escript eth_bench.escript \
%%       --url http://127.0.0.1:8545 \
%%       --method eth_call \
%%       --concurrency 16 --duration 10
%%
%% Options:
%%   --url <url>            target JSON-RPC HTTP endpoint
%%   --method <name>        Ethereum method to call
%%   --payload <json|@file> full JSON-RPC body; prefix with @ to read a file
%%                          (defaults to a balanceOf call on Sepolia WETH)
%%   --concurrency <n>      number of parallel workers
%%   --duration <s>         run for this many seconds (default 10)
%%   --requests <n>         instead: issue this many requests total
%%   --warmup <s>           discard results for the first <s> seconds (default 1)
%%   --timeout <ms>         per-request HTTP timeout (default 30000)

-mode(compile).

main(Args) ->
    Cfg = parse_args(Args, #{
        url => "http://127.0.0.1:8545",
        method => <<"eth_call">>,
        payload => undefined,
        concurrency => 8,
        duration => 10,
        requests => 0,
        warmup => 1,
        timeout => 30000
    }),
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Payload = ensure_payload(Cfg),
    io:format("eth_bench: url=~s method=~s concurrency=~p duration=~ps warmup=~ps~n",
              [maps:get(url, Cfg), maps:get(method, Cfg),
               maps:get(concurrency, Cfg), maps:get(duration, Cfg),
               maps:get(warmup, Cfg)]),
    run(Cfg, Payload),
    ok.

%% ---------------------------------------------------------------------------
%% arg parsing
%% ---------------------------------------------------------------------------

parse_args([], Acc) -> Acc;
parse_args(["--url", V | T], A) -> parse_args(T, A#{url := V});
parse_args(["--method", V | T], A) -> parse_args(T, A#{method := list_to_binary(V)});
parse_args(["--payload", V | T], A) -> parse_args(T, A#{payload := V});
parse_args(["--concurrency", V | T], A) -> parse_args(T, A#{concurrency := to_int(V)});
parse_args(["--duration", V | T], A) -> parse_args(T, A#{duration := to_int(V)});
parse_args(["--requests", V | T], A) -> parse_args(T, A#{requests := to_int(V)});
parse_args(["--warmup", V | T], A) -> parse_args(T, A#{warmup := to_int(V)});
parse_args(["--timeout", V | T], A) -> parse_args(T, A#{timeout := to_int(V)});
parse_args([_ | T], A) -> parse_args(T, A).

to_int(S) -> list_to_integer(S).

ensure_payload(#{payload := undefined, method := Method}) ->
    list_to_binary(default_payload(Method));
ensure_payload(#{payload := "@" ++ File}) ->
    case file:read_file(File) of
        {ok, Bin} -> Bin;
        {error, R} -> error({read_payload, File, R})
    end;
ensure_payload(#{payload := Json}) ->
    list_to_binary(Json).

default_payload(<<"eth_call">>) ->
    %% balanceOf(0x...0001) on a real Sepolia contract: exercises upstream EVM.
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":["
    "{\"to\":\"0xfff9976782d46cc05630d1f6ebab18b2324d6b14\","
    "\"data\":\"0x70a082310000000000000000000000000000000000000000000000000000000000000001\"},"
    "\"latest\"]}";
default_payload(<<"eth_blockNumber">>) ->
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_blockNumber\",\"params\":[]}";
default_payload(<<"eth_getBalance">>) ->
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\","
    "\"params\":[\"0x0000000000000000000000000000000000000001\",\"latest\"]}";
default_payload(<<"eth_getBlockByNumber">>) ->
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBlockByNumber\","
    "\"params\":[\"latest\",false]}" .

%% ---------------------------------------------------------------------------
%% load generator
%% ---------------------------------------------------------------------------

run(Cfg, Payload) ->
    Tab = ets:new(bench, [ordered_set]),
    ets:insert(Tab, {stop, false}),
    C = maps:get(concurrency, Cfg),
    Total = maps:get(requests, Cfg),
    Duration = maps:get(duration, Cfg),
    Warmup = maps:get(warmup, Cfg),
    StartSec = erlang:monotonic_time(second),
    StopAt = StartSec + Duration,
    WarmEnd = StartSec + Warmup,
    Collector = self(),
    Pids = [spawn(fun() ->
                      worker_loop(Cfg, Payload, Tab, StopAt, WarmEnd, Collector)
                  end) || _ <- lists:duplicate(C, dummy)],
    collect(Pids, Cfg, Tab, Total, StopAt, WarmEnd, StartSec, 0, 0, 0, never, never, []).

worker_loop(Cfg, Payload, Tab, StopAt, WarmEnd, Collector) ->
    case time_up(Tab, StopAt) of
        true -> ok;
        false ->
            T0 = mon_us(),
            Result = do_request(Cfg, Payload),
            T1 = mon_us(),
            Warm = erlang:monotonic_time(second) < WarmEnd,
            Collector ! {done, T1 - T0, Result, Warm},
            worker_loop(Cfg, Payload, Tab, StopAt, WarmEnd, Collector)
    end.

time_up(Tab, StopAt) ->
    case ets:lookup(Tab, stop) of
        [{stop, true}] -> true;
        _ -> erlang:monotonic_time(second) >= StopAt
    end.

do_request(Cfg, Payload) ->
    Headers = [{"content-type", "application/json"}],
    try httpc:request(post, {maps:get(url, Cfg), Headers, "application/json", Payload},
                      [{timeout, maps:get(timeout, Cfg)},
                       {connect_timeout, 5000}],
                      [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, _}} when Code =:= 200 -> ok;
        {ok, {{_, Code, _}, _, _}} -> {http, Code};
        {error, R} -> {conn, R}
    catch Class:Reason -> {Class, Reason}
    end.

%% ---------------------------------------------------------------------------
%% collector
%% ---------------------------------------------------------------------------

collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec, Done, Ok, Err,
        LastSec, MeasStart, Acc) ->
    Now = erlang:monotonic_time(second),
    case Now > LastSec of
        true ->
            io:format("  ~p elapsed = ~ps   done=~p ok=~p err=~p~n",
                      [Done, Now - StartSec, Done, Ok, Err]),
            collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec,
                    Done, Ok, Err, Now, MeasStart, Acc);
        false ->
            receive
                {done, _Lat, ok, Warm} when Warm ->
                    collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec,
                            Done, Ok, Err, LastSec, MeasStart, Acc);
                {done, Lat, ok, _} ->
                    collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec,
                            Done + 1, Ok + 1, Err, LastSec,
                            first_measure(MeasStart), [Lat | Acc]);
                {done, _Lat, _Status, Warm} when Warm ->
                    collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec,
                            Done, Ok, Err, LastSec, MeasStart, Acc);
                {done, Lat, _Status, _} ->
                    collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec,
                            Done + 1, Ok, Err + 1, LastSec,
                            first_measure(MeasStart), [Lat | Acc]);
                stop ->
                    collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec,
                            Done, Ok, Err, LastSec, MeasStart, Acc)
            after 250 ->
                case finished(Tab, Total, Deadline, Done) of
                    true ->
                        ets:insert(Tab, {stop, true}),
                        timer:sleep(200),
                        ElapsedUs = case MeasStart of
                                        never -> 0;
                                        _ -> mon_us() - MeasStart
                                    end,
                        report(Cfg, Done, Ok, Err, ElapsedUs, Acc);
                    false ->
                        collect(Pids, Cfg, Tab, Total, Deadline, WarmEnd, StartSec,
                                Done, Ok, Err, LastSec, MeasStart, Acc)
                end
            end
    end.

first_measure(never) -> mon_us();
first_measure(V) -> V.

finished(Tab, 0, Deadline, _Done) ->
    time_up(Tab, Deadline);
finished(_Tab, Total, _Deadline, Done) when Done >= Total -> true;
finished(Tab, _Total, Deadline, _Done) ->
    time_up(Tab, Deadline).

report(Cfg, Done, Ok, Err, ElapsedUs, Lats) ->
    Sorted = lists:sort(Lats),
    N = length(Sorted),
    Avg = case N of 0 -> 0; _ -> lists:sum(Sorted) div N end,
    Min = case Sorted of [] -> 0; [H | _] -> H end,
    Max = case Sorted of [] -> 0; _ -> lists:last(Sorted) end,
    ElapsedS = ElapsedUs / 1000000,
    Rate = case ElapsedS of 0 -> 0.0; _ -> Done / ElapsedS end,
    io:format("~n================ eth_bench results ================~n"),
    io:format("  method      : ~s~n", [maps:get(method, Cfg)]),
    io:format("  url         : ~s~n", [maps:get(url, Cfg)]),
    io:format("  concurrency : ~p~n", [maps:get(concurrency, Cfg)]),
    io:format("  requests    : ~p (ok=~p, err=~p)~n", [Done, Ok, Err]),
    io:format("  elapsed     : ~.2fs~n", [ElapsedS]),
    io:format("  throughput  : ~.1f req/s~n", [Rate]),
    io:format("  latency(us) : min=~p avg=~p p50=~p p90=~p p99=~p max=~p~n",
              [Min, Avg, perc(Sorted, 50), perc(Sorted, 90), perc(Sorted, 99), Max]),
    io:format("==================================================~n").

perc([], _) -> 0;
perc(List, P) ->
    Idx = max(1, round(length(List) * P / 100)),
    lists:nth(Idx, List).

mon_us() -> erlang:monotonic_time(microsecond).