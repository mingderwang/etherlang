-module(eth_rate_limit_tests).

-include_lib("eunit/include/eunit.hrl").

token_bucket_test() ->
    Tab = eth_rate_limit:start(0, 0),
    %% Rate =< 0 disables limiting entirely.
    ?assert(eth_rate_limit:take(Tab, k, 0, 0)),
    ?assert(eth_rate_limit:take(Tab, k, 0, 0)),
    eth_rate_limit:stop(Tab),
    ok.

burst_exhaustion_test() ->
    Tab = eth_rate_limit:start(1, 2),
    %% Burst of 2 on a fresh key: two grants, then denial for the same key.
    ?assert(eth_rate_limit:take(Tab, src, 1, 2)),
    ?assert(eth_rate_limit:take(Tab, src, 1, 2)),
    ?assertNot(eth_rate_limit:take(Tab, src, 1, 2)),
    %% Different key is unaffected (per-source isolation).
    ?assert(eth_rate_limit:take(Tab, other, 1, 2)),
    eth_rate_limit:stop(Tab),
    ok.

refill_test() ->
    Tab = eth_rate_limit:start(2, 5),
    _ = [begin ?assert(eth_rate_limit:take(Tab, src, 2, 5)) end || _ <- lists:seq(1, 5)],
    ?assertNot(eth_rate_limit:take(Tab, src, 2, 5)),
    %% 100ms later ~0.2 token recovered; still below 1 -> still denied.
    timer:sleep(100),
    %% Enough time (~500ms) for >= 1 token at 2/s -> granted again.
    timer:sleep(500),
    ?assert(eth_rate_limit:take(Tab, src, 2, 5)),
    eth_rate_limit:stop(Tab),
    ok.