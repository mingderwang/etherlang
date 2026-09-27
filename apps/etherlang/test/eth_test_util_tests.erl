%% Tests for the test helpers themselves.
%%
%% with_port/1 exists because a port collision killed a test with a
%% *cancelled* result and no assertion: EUnit reported "One or more tests were
%% cancelled" and the suite exited non-zero, which reads like a runner problem
%% and is not one. free_port/0 listens on port 0, reads back the number the OS
%% chose, and closes the socket, so the number is unowned for a moment and
%% anything else in the VM can take it. These tests pin the behaviour that
%% makes that survivable.

-module(eth_test_util_tests).

-include_lib("eunit/include/eunit.hrl").

%% The contract every caller relies on: the port handed back is one this
%% process can actually bind. If with_port/1 ever returns a port it did not
%% verify, this is the test that says so.
the_port_it_hands_back_is_bindable_test() ->
    ?assertEqual(ok, eth_test_util:with_port(fun(Port) ->
        {ok, L} = gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}},
                                        {reuseaddr, true}]),
        gen_tcp:close(L),
        ok
    end)).

%% The retry itself, driven through the caller's function: bind a port that is
%% genuinely already bound, twice, then succeed. with_port/1 must absorb both
%% collisions and return the eventual success rather than propagating the first
%% failure.
%%
%% The failure is produced by a real bind on a real occupied port rather than
%% by raising a term that looks like one. That distinction earned its keep: an
%% earlier version of this test raised a literal {badmatch, {error, eaddrinuse}}
%% and a matcher written for a bare `eaddrinuse` re-raised on the first
%% collision, leaving the retry decorative. A real bind is the only way to be
%% sure the shape being matched is the shape that arrives -- and the shape
%% depends on the caller writing `{ok, _} = Mod:start_link(...)`, which is what
%% every caller in this suite does.
retries_through_a_taken_port_test() ->
    {ok, Occupied} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}},
                                        {reuseaddr, true}]),
    {ok, Taken} = inet:port(Occupied),
    Counter = counters:new(1, []),
    try
        ?assertEqual(bound, eth_test_util:with_port(fun(_Port) ->
            case counters:get(Counter, 1) of
                0 -> counters:add(Counter, 1, 1), collide(Taken);
                1 -> counters:add(Counter, 1, 1), collide(Taken);
                _ -> bound
            end
        end)),
        %% Three calls reached the function: two collisions and one success.
        %% A loop that gave up early, or that succeeded first time, fails here.
        ?assertEqual(2, counters:get(Counter, 1))
    after
        gen_tcp:close(Occupied)
    end.

%% Exactly what a caller's `{ok, _} = Mod:start_link(...)` turns a lost bind
%% into, produced by actually losing one.
collide(Taken) ->
    {ok, _} = gen_tcp:listen(Taken, [{ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    ok.

%% A failure that is not a port collision must propagate untouched. If this
%% retried, a genuine defect in a module under test would be reported as a
%% flaky port and swallowed five times before surfacing.
a_real_failure_is_not_retried_test() ->
    ?assertError(boom, eth_test_util:with_port(fun(_Port) ->
        error(boom)
    end)).

%% ...and it must keep its own reason rather than being re-raised from inside
%% the retry loop with the helper's stack, or the traceback would point at
%% eth_test_util instead of at the code that actually failed.
a_real_failure_keeps_its_own_reason_test() ->
    ?assertError({boom, from_the_caller}, eth_test_util:with_port(fun(_Port) ->
        error({boom, from_the_caller})
    end)).

%% A throw -- not an error -- must also pass straight through. The catch
%% matches on Class too, so a throw that is not a bind failure must not be
%% turned into a retry either.
a_throw_is_not_retried_test() ->
    ?assertThrow(fly, eth_test_util:with_port(fun(_Port) ->
        throw(fly)
    end)).

%% The retry budget is bounded. A caller whose port is never free gets a
%% distinct, readable failure instead of looping forever -- the alternative
%% being a suite that hangs until the runner's timeout.
the_retry_budget_is_bounded_test() ->
    {ok, Occupied} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}},
                                        {reuseaddr, true}]),
    {ok, Taken} = inet:port(Occupied),
    try
        ?assertError({port_exhausted, _}, eth_test_util:with_port(
            fun(_Port) -> collide(Taken) end))
    after
        gen_tcp:close(Occupied)
    end.

%% free_port/0 alone is still racy by construction; callers that cannot use
%% with_port/1 get no retry. Twenty consecutive draws must be distinct, which
%% is the weakest useful statement -- it holds almost always, and fails loudly
%% if something starts handing out a fixed port.
consecutive_draws_differ_test() ->
    Ports = [eth_test_util:free_port() || _ <- lists:seq(1, 20)],
    ?assertEqual(20, length(lists:usort(Ports))).
