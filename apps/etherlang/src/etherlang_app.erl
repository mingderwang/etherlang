%% -*- erlang -*-
-module(etherlang_app).
-behaviour(application).

-export([start/2, stop/1, check_config/0]).

%% The decision, separated from the work, because "does this node start" and "is this
%% configuration usable" are two questions and only the second is answerable without
%% standing up a supervision tree, a DETS file and two listeners.
%%
%% A test that calls `start/2' to find out whether the gate lets a *legal* configuration
%% through boots the node -- it opens `eth_mpt' under `DATA_DIR', generates a JWT secret
%% into `./data', and binds 8545 and 8551. That is the trap in AGENTS.md §10a, a
%% resource this module did not scope touched by a test that meant to observe a decision.
%%
%% So the answer has its own name, and it is a **one-line pass-through on purpose**: it
%% adds no behaviour and could be inlined, and that is the point. It is a *seam*, so that
%% "does the node start" and "is this configuration usable" are two calls rather than one,
%% and a test can ask the second without paying for the first. A wrapper that only
%% re-labels its argument is worth nothing unless it is the thing you call instead of the
%% thing with side effects.
check_config() ->
    eth_config_settings:validate().

%% Refuses to start on a configuration the node cannot honour, and says which variables
%% and why.
%%
%% `eth_config:validate/0' did not exist when this was a bare
%% `etherlang_sup:start_link()', and the absence is not neutral: the accessors answer a
%% **default** for a value they cannot parse and answer a **nonsense value as written**
%% for one they can, so `CHAIN_RETENTION=abc' produced a node retaining 2048 blocks that
%% no log line mentioned, and `CHAIN_RETENTION=-5' produced a node retaining -5 of them
%% and used it. Both are only findable at startup, and by the time a bad retention is
%% visible as pruned history the cause is gone.
%%
%% The accessors keep that behaviour on purpose. A unit test that sets a nonsense
%% variable to prove something about parsing should not take the suite down with it, and
%% the fallback is what a library function owes its caller. The gate belongs here, where
%% "start the node" is a decision rather than a lookup.
%%
%% Warnings are logged and do not stop the node: a node bound to `0.0.0.0' is correct
%% and exposed, and refusing to boot an operator out of a configuration they chose on
%% purpose is a worse answer than saying so once.
start(_StartType, _StartArgs) ->
    %% **Which build is this, printed before anything else can refuse to run.**
    %%
    %% `make release-pair` sets `ETH_BUILD_STAMP` to `<git sha>-<epoch>` and then asserts that
    %% exact string appears in the log this process just wrote. **The first version of that
    %% gate asserted a marker from a *connection* diagnostic**, which cannot be satisfied when
    %% no peer has connected -- an instrument with no positive result, which is worse than no
    %% instrument, and it reported a healthy build as stale.
    %%
    %% It is here rather than after `check_config/0` on purpose: a node that refuses to boot is
    %% exactly the case where knowing *which* build refused is worth the most.
    logger:notice("etherlang: build stamp ~ts", [build_stamp()]),
    case check_config() of
        {error, Problems} ->
            logger:error("refusing to start: configuration is not usable", #{
                problems => [format_problem(P) || P <- Problems]}),
            {error, {invalid_configuration, Problems}};
        {ok, Warnings} ->
            [logger:warning("configuration: ~s", [format_problem(W)]) || W <- Warnings],
            start_unchecked()
    end.

%% **Absent is a value here.** A node started by hand rather than by `make release-pair'
%% answers `unstamped', and that string in a log is the reason a freshness check cannot
%% conclude anything -- so it is stated rather than left blank.
build_stamp() ->
    case os:getenv("ETH_BUILD_STAMP") of
        false -> "unstamped";
        S -> S
    end.

format_problem({Var, Given, Why}) ->
    io_lib:format("~s=~s -- ~ts", [Var, Given, Why]).

start_unchecked() ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    eth_rpc_client:init(#{url => eth_config:upstream_url(),
                          timeout_ms => eth_config:http_timeout_ms(),
                          retries => 3,
                          backoff_ms => 1000}),
    etherlang_sup:start_link().

stop(_State) ->
    ok.
