-module(eth_rate_limit).

%% Per-source token bucket for the JSON-RPC endpoint. Rate is refilled
%% continuously (requests/second), with a burst allowance; each request
%% consumes one token. Denial is per-key (source IP), so one noisy client
%% cannot starve the others.

-export([start/2, stop/1, take/4]).

start(Rate, Burst) when is_integer(Rate), Rate >= 0, is_integer(Burst), Burst >= 0 ->
    ets:new(eth_rpc_ratelimit,
            [public, set, {read_concurrency, true}, {write_concurrency, true}]).

stop(Tab) when is_reference(Tab); is_integer(Tab) ->
    try ets:delete(Tab) catch _:_ -> ok end.

%% Rate =< 0 disables limiting (allow everything). Otherwise true if a token
%% is available (consumes it), false if the burst is exhausted.
take(_Tab, _Key, Rate, _Burst) when Rate =< 0 ->
    true;
take(Tab, Key, Rate, Burst) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(Tab, Key) of
        [] ->
            ets:insert(Tab, {Key, Now, Burst - 1.0}),
            true;
        [{Key, Last, Tok}] ->
            Tok2 = min(Burst, Tok + ((Now - Last) * Rate) / 1000),
            case Tok2 >= 1.0 of
                true ->
                    ets:insert(Tab, {Key, Now, Tok2 - 1.0}),
                    true;
                false ->
                    ets:insert(Tab, {Key, Now, Tok2}),
                    false
            end
    end.