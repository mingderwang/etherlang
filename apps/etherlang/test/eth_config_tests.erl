%% -*- erlang -*-
%% Configuration validation.
%%
%% Every test here states a property of the **pair** -- what the accessor answers and what
%% `validate/0' says about the same value -- because the two disagreeing *is* the defect.
%% A test asserting only that a problem is reported passes against accessors that report
%% problems and do nothing about them, which is the state this tree was in before the
%% change: every value in `?SWALLOWED' below "worked", silently and wrongly.
%%
%% The environment is process-wide and this suite has ~750 other tests reading it, so
%% every test here goes through `with_env/2', which restores what it found. `DATA_DIR' is
%% in that set because `eth_mpt' opens a DETS file under it.
-module(eth_config_tests).

-include_lib("eunit/include/eunit.hrl").

%% The values `eth_config:int_env/3' and `str_env/3' silently accepted, measured on this
%% tree before the change. This list *is* the specification of the fix: a value dropped
%% from it has had its defect reinstated and nothing else would say so.
-define(SWALLOWED, [
    {"CHAIN_RETENTION", "abc",        "not a number"},
    {"CHAIN_RETENTION", "-5",         "at least 1"},
    {"CHAIN_RETENTION", "0",          "at least 1"},
    {"BODY_WINDOW",     "-1",         "not be negative"},
    {"POLL_INTERVAL_MS", "-1",        "at least 1"},
    {"SYNC_CONCURRENCY", "0",         "at least 1"},
    {"PEER_TARGET",     "-1",         "not be negative"},
    {"RPC_LISTEN_PORT", "99999",      "not a TCP port"},
    {"RPC_LISTEN_PORT", "0",          "not a TCP port"},
    {"RPC_LISTEN_PORT", "notaport",   "not a number"},
    {"ENGINE_PORT",     "65536",      "not a TCP port"},
    {"RPC_LISTEN_IP",   "1.999.1.1",  "dotted-quad"},
    {"RPC_LISTEN_IP",   "10.0.0.256", "dotted-quad"},
    {"RPC_LISTEN_IP",   "nonsense",   "dotted-quad"},
    {"RPC_LISTEN_IP",   "999.1.1.1",  "dotted-quad"},
    {"RPC_LISTEN_IP",   "1.2.3",      "dotted-quad"},
    {"RPC_LISTEN_IP",   "1.2.3.4.5",  "dotted-quad"},
    {"ETH_START_BLOCK", "garbage",    "block number"},
    {"VERIFY_HEADERS",  "maybe",      "not a boolean"},
    {"DISCV4_BOOTNODES", "not-an-enode", "enode://"},
    {"UPSTREAM_RPC_URL", "sepolia-rpc.example.com", "absolute URL"},
    {"ETH_NETWORK",     "holesky",    "fork table"},
    {"ETH_FORK",        "shangai",    "gas schedule"}]).

unparseable_values_are_reported_test_() ->
    [{lists:flatten(io_lib:format("~s=~s", [Var, Given])),
      ?_test(begin
                 with_env([{Var, Given}],
                          fun() ->
                              {error, Problems} = eth_config_settings:validate(),
                              %% Exactly one, not "at least one": a validator that
                              %% reported every variable for every value would satisfy a
                              %% weaker assertion and say nothing about which one.
                              [{_, Reported, Why}] = problems_for(Var, Problems),
                              ?assertEqual(Given, Reported),
                              ?assert(string:find(Why, Expected) =/= nomatch)
                          end)
             end)}
     || {Var, Given, Expected} <- ?SWALLOWED].

%% The other half, and the half that was the actual bug: the accessor must not *build* a
%% value out of something it cannot parse. `listen_ip/0' answered {1,999,1,1} for
%% `1.999.1.1' -- a tuple `inet' answers `einval' for, so the malformed address reached
%% `cowboy' and failed there as a listener error, which says nothing about a setting.
%%
%% Asserted through `listen_ip/0' rather than a parser, because `listen_ip/0' is the
%% exported surface and it is the function that was wrong. A test on a parser alone would
%% pass with `listen_ip/0' still building the tuple.
an_out_of_range_octet_is_not_an_address_test() ->
    Bad = ["1.999.1.1", "10.0.0.256", "256.1.1.1", "1.2.3.4.5", "1.2.3",
           "1..2.3", "1.2.3.x", "0x7f.0.0.1"],
    [?assertEqual(error, eth_config_settings:ip4(S)) || S <- Bad],
    [begin
         with_env([{"RPC_LISTEN_IP", S}],
                  fun() ->
                      ?assertEqual({127, 0, 0, 1}, eth_config:listen_ip()),
                      {error, _} = eth_config_settings:validate()
                  end)
     end || S <- Bad].

a_valid_dotted_quad_still_parses_test() ->
    lists:foreach(fun({Str, Want}) -> ?assertEqual({ok, Want}, eth_config_settings:ip4(Str)) end,
                  [{"127.0.0.1", {127, 0, 0, 1}},
                   {"0.0.0.0", {0, 0, 0, 0}},
                   {"10.0.0.1", {10, 0, 0, 1}},
                   {"255.255.255.255", {255, 255, 255, 255}},
                   {" 192.168.1.1 ", {192, 168, 1, 1}}]).

%% `999.1.1.1' has always answered loopback, because `listen_ip/0' fell back, and it still
%% does: the accessor is a lookup and the gate is at startup. What changed is that it is
%% no longer the *whole* answer. A test asserting `listen_ip/0' raises would be a test
%% written against a design this change deliberately does not have.
a_mistyped_bind_address_is_reported_rather_than_silently_made_loopback_test() ->
    with_env([{"RPC_LISTEN_IP", "999.1.1.1"}],
             fun() ->
                 ?assertEqual({127, 0, 0, 1}, eth_config:listen_ip()),
                 {error, Problems} = eth_config_settings:validate(),
                 ?assertEqual(1, length(problems_for("RPC_LISTEN_IP", Problems)))
             end).

%% A legal value must still pass, or every test above is satisfied by a `validate/0'
%% that rejects everything.
accepted_values_are_not_problems_test_() ->
    [{lists:flatten(io_lib:format("~s=~s", [Var, Given])),
      ?_test(begin
                 with_env([{Var, Given}],
                          fun() ->
                              {ok, _} = eth_config_settings:validate()
                          end)
             end)}
     || {Var, Given} <- [{"CHAIN_RETENTION", "2048"},
                         {"CHAIN_RETENTION", " 512 "},
                         {"BODY_WINDOW", "0"},
                         {"PEER_TARGET", "0"},
                         {"RPC_LISTEN_PORT", "1"},
                         {"RPC_LISTEN_PORT", "65535"},
                         {"RPC_LISTEN_IP", "0.0.0.0"},
                         {"RPC_LISTEN_IP", "10.1.2.3"},
                         {"ETH_START_BLOCK", "latest"},
                         {"ETH_START_BLOCK", "0x1a2b3c"},
                         {"ETH_START_BLOCK", "1450507"},
                         {"VERIFY_HEADERS", "true"},
                         {"VERIFY_HEADERS", "on"},
                         {"VERIFY_HEADERS", "NO"},
                         {"DISCV4_BOOTNODES", "enode://abc@1.2.3.4:30303"},
                         {"DISCV4_BOOTNODES", "enode://a@1.2.3.4:30303,enode://b@5.6.7.8:30303"},
                         {"UPSTREAM_RPC_URL", "https://ethereum-sepolia-rpc.publicnode.com"},
                         {"UPSTREAM_RPC_URL", "http://127.0.0.1:8545"},
                         {"ETH_NETWORK", "mainnet"},
                         {"ETH_NETWORK", "1"},
                         {"ETH_NETWORK", "sepolia"},
                         {"ETH_NETWORK", "11155111"},
                         {"ETH_FORK", "shanghai"},
                         {"ETH_FORK", "Osaka"}]].

an_unset_variable_is_the_default_and_not_a_problem_test() ->
    with_env([{"CHAIN_RETENTION", false}],
             fun() ->
                 {ok, _} = eth_config_settings:validate(),
                 ?assertEqual(2048, eth_config:chain_retention())
             end).

an_empty_variable_is_the_default_and_not_a_problem_test() ->
    %% `str_env/3' treats "" as unset, so `DATA_DIR=""' is not a broken path, it is no
    %% setting at all. Calling it a problem would be inventing an intent.
    with_env([{"DATA_DIR", ""}],
             fun() -> {ok, _} = eth_config_settings:validate() end).

%% A kind with no clause must not validate. The catch-all `parse(_Kind, _V) -> ok' was in
%% this module for one commit, and it would have made a mistyped entry in `settings/0'
%% report as checked while checking nothing -- an accumulator that records a decision
%% without gating the behaviour it recorded.
an_unknown_kind_is_an_error_and_not_a_pass_test() ->
    ?assertMatch({error, _}, eth_config_settings:parse(nonesuch, "1")).

the_table_names_only_kinds_that_are_checked_test() ->
    Known = eth_config_settings:kinds(),
    ?assertEqual([], [{V, K} || {V, K} <- eth_config_settings:settings(),
                              not lists:member(K, Known)]).

the_table_has_no_duplicate_variable_test() ->
    Vars = [V || {V, _} <- eth_config_settings:settings()],
    ?assertEqual(lists:usort(Vars), lists:sort(Vars)).

%% Every variable `eth_config' reads must be in the table, or it is an unchecked setting.
%% Derived from the source rather than transcribed, so a new `int_env/3' added without a
%% table entry fails here instead of being silently unvalidated -- which is the only way a
%% new setting would ever be found to be missing from here.
every_variable_eth_config_reads_is_in_the_table_test() ->
    Read = env_vars_read_by("apps/etherlang/src/eth_config.erl"),
    %% An empty scan would make the assertion below vacuously true.
    ?assert(length(Read) >= 25),
    ?assert(lists:member("CHAIN_RETENTION", Read)),
    InTable = [V || {V, _} <- eth_config_settings:settings()],
    ?assertEqual([], [V || V <- Read, not lists:member(V, InTable)]).

%% And the two that are read elsewhere rather than by `eth_config' must be in the table
%% too, or a setting read by a module the scan cannot see is unchecked by construction.
the_name_settings_read_elsewhere_are_in_the_table_test() ->
    InTable = [V || {V, _} <- eth_config_settings:settings()],
    ?assert(lists:member("ETH_NETWORK", InTable)),
    ?assert(lists:member("ETH_FORK", InTable)).

%% ---------------------------------------------------------------------------
%% Warnings: the node is correct in each of these and the operator may not have meant it,
%% so a refusal would be a worse answer than a log line.

a_public_bind_is_a_warning_and_not_a_refusal_test() ->
    with_env([{"RPC_LISTEN_IP", "0.0.0.0"}, {"RPC_API_KEY", false}],
             fun() ->
                 {ok, Warnings} = eth_config_settings:validate(),
                 ?assert(problems_about(Warnings, "RPC_LISTEN_IP")),
                 ?assertEqual({0, 0, 0, 0}, eth_config:listen_ip())
             end).

two_listeners_on_one_port_is_a_warning_test() ->
    with_env([{"DISCV4_ENABLED", "true"}, {"RLPX_ENABLED", "true"}],
             fun() ->
                 {ok, Warnings} = eth_config_settings:validate(),
                 ?assert(problems_about(Warnings, "DISCV4_PORT"))
             end).

retention_below_the_body_window_is_a_warning_test() ->
    %% Defaults are 2048 and 2048, so a node keeping 100 blocks but told to hold bodies on
    %% 2048 prunes the bodies it asked for. Not a refusal: the node works, and the
    %% operator may have set BODY_WINDOW for a different reader of the value.
    with_env([{"CHAIN_RETENTION", "100"}, {"BODY_WINDOW", "2048"}],
             fun() ->
                 {ok, Warnings} = eth_config_settings:validate(),
                 ?assert(problems_about(Warnings, "CHAIN_RETENTION"))
             end).

no_warnings_for_a_loopback_node_with_nothing_set_test() ->
    with_env([{"RPC_LISTEN_IP", "127.0.0.1"}, {"DISCV4_ENABLED", "false"},
              {"RLPX_ENABLED", "false"}, {"CHAIN_RETENTION", false},
              {"BODY_WINDOW", false}],
             fun() -> ?assertEqual({ok, []}, eth_config_settings:validate()) end).

%% ---------------------------------------------------------------------------
%% The gate itself. `check_config/0' for both directions, because the negative direction
%% alone is satisfied by a gate that refuses everything -- which is the failure a test
%% written only against `start/2' would have shipped.
an_unusable_configuration_fails_the_gate_test() ->
    with_env([{"CHAIN_RETENTION", "-5"}],
             fun() -> ?assertMatch({error, _}, etherlang_app:check_config()) end).

a_usable_configuration_passes_the_gate_test() ->
    with_env([{"CHAIN_RETENTION", "2048"}],
             fun() -> ?assertMatch({ok, _}, etherlang_app:check_config()) end).

%% `start/2' refuses, and returns before starting anything -- no MPT, no JWT secret, no
%% listener. That it returns *early* is the property worth pinning, and the observable
%% form of it is that the answer is about the configuration.
the_node_refuses_to_start_on_an_unusable_configuration_test() ->
    with_env([{"CHAIN_RETENTION", "-5"}],
             fun() ->
                 ?assertMatch({error, {invalid_configuration, _}},
                              etherlang_app:start(normal, []))
             end).

%% This is the control the negative test above needs, and it is stated as a fact about
%% the filesystem rather than about a return value: a gate that reported an error but
%% started the node anyway would pass the test above. `./data/jwt.hex` is written by
%% `eth_rpc_server`'s start-up, so its absence is evidence that nothing was started.
the_refusal_happens_before_anything_is_started_test() ->
    Dir = eth_test_util:tmp_dir(),
    Jwt = filename:join([Dir, "jwt.hex"]),
    ?assertNot(filelib:is_regular(Jwt)),
    with_env([{"CHAIN_RETENTION", "-5"}, {"DATA_DIR", Dir}],
             fun() ->
                 ?assertMatch({error, {invalid_configuration, _}},
                              etherlang_app:start(normal, [])),
                 ?assertNot(filelib:is_regular(Jwt))
             end).

%% ---------------------------------------------------------------------------
%% Helpers

problems_for(Var, Problems) -> [P || P = {V, _, _} <- Problems, V =:= Var].

problems_about(Warnings, Var) -> problems_for(Var, Warnings) =/= [].

%% Every string literal in a source file, by splitting on the delimiter rather than with
%% `re:run/3'. `re:run/3' returns the **first** match only -- `not_global` is its
%% documented default -- so the obvious `re:run/3` scan of this file finds one variable
%% and reports thirty-one variables read as all of them checked, which is the exact shape
%% of the defect it was written to catch. Splitting on `"' and taking the odd-indexed
%% tokens is every literal, with no option to get wrong.
env_vars_read_by(Path) ->
    {ok, Bin} = file:read_file(source_path(Path)),
    Parts = string:split(Bin, <<"\"">>, all),
    %% Split on `"' gives [text, literal, text, literal, ..., text], so the literals are
    %% the odd zero-based indices.
    [binary_to_list(L) || {I, L} <- lists:zip(lists:seq(0, length(Parts) - 1), Parts),
                          I rem 2 =:= 1,
                          is_env_name(L)].

%% An environment variable name: uppercase, digits and underscores, at least two
%% characters so that a one-letter literal cannot qualify.
is_env_name(<<>>) -> false;
is_env_name(<<C, Rest/binary>>) ->
    C >= $A andalso C =< $Z andalso
        lists:all(fun(K) -> (K >= $A andalso K =< $Z) orelse
                               (K >= $0 andalso K =< $9) orelse K =:= $_ end,
                binary_to_list(Rest)).

%% The source sits beside the beam under both `rebar3 compile` and `rebar3 eunit`, so this
%% does not depend on the working directory -- which is not the project root under
%% `eunit`, and a test reading `apps/etherlang/src/...` relative to the cwd passes or
%% fails on how it was invoked.
source_path(Path) ->
    Ebin = filename:dirname(code:which(eth_config)),
    Candidate = filename:join([filename:dirname(Ebin), "src", Path]),
    case filelib:is_regular(Candidate) of
        true -> Candidate;
        false -> Path
    end.

%% Set environment variables, run `Fun`, and put every one of them back exactly as it was.
%% A value of `false` means **unset**, which `os:putenv/2' cannot express -- it raises
%% `badarg' on a non-list -- and `str_env/3' treats unset and "" identically, so the two
%% are the same configuration here and only one of them is expressible.
with_env(Vars, Fun) ->
    Names = lists:usort([N || {N, _} <- Vars] ++
                        ["ETH_NETWORK", "ETH_FORK", "DATA_DIR", "RPC_API_KEY"]),
    Saved = [{N, os:getenv(N)} || N <- Names],
    [set_env(N, V) || {N, V} <- Vars],
    try Fun()
    after
        [set_env(N, V) || {N, V} <- Saved]
    end.

set_env(Name, false) -> os:unsetenv(Name);
set_env(Name, Value) -> os:putenv(Name, Value).
