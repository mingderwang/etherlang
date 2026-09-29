%% -*- erlang -*-
%% Configuration validation.
%%
%% `int_env/3' answers the **default** for any value it cannot parse, and answers the
%% **value as written** for anything that parses -- including a negative one. Measured on
%% this tree before the change:
%%
%%     CHAIN_RETENTION=abc          ->  2048     the default, silently
%%     CHAIN_RETENTION=-5           ->  -5       and it is used
%%     BODY_WINDOW=-1               ->  -1
%%     POLL_INTERVAL_MS=-1          ->  -1       `timer:sleep/1' would raise on it
%%     RPC_LISTEN_PORT=99999        ->  99999    not a port
%%     RPC_LISTEN_PORT=notaport     ->  8545     the default, silently
%%     ETH_START_BLOCK=garbage      ->  latest   silently
%%     SYNC_CONCURRENCY=0           ->  0
%%
%% The silent substitutions are the ones that matter, and they are not all the same
%% severity. A default substituted for a typo is a node running with configuration the
%% operator did not ask for, and there is nothing anywhere that says so. `RPC_LISTEN_IP`
%% is the sharpest case: an operator who asked to expose the RPC and mistyped the address
%% gets **loopback**, because the address does not parse and `listen_ip/0' falls back.
%% The node
%% looks correctly configured and is not reachable, which is the safe direction by luck
%% rather than by design.
%%
%% So: the accessors keep their behaviour, because a unit test that sets a nonsense
%% variable should not take the suite down with it, and `etherlang_app:start/2` calls
%% `validate/0' and **refuses to start** when it answers `{error, Problems}'. Refusing at
%% startup is the only place this can be caught: by the time a bad retention is visible
%% as pruned history, the cause is gone.
%%
%% `validate/0' reads `os:getenv/1' only, and that is the **whole** of the scope rather
%% than a shortcut: `str_env/3' is `str_env(Env, _Key, Default)' and never consults
%% `application:get_env/2' at all, so the application environment this module's header
%% claims as its second source has never existed. The header now says what the code does.
-module(eth_config_settings).

-export([validate/0, parse/2, ip4/1, kinds/0, settings/0]).

%% The settings table: `{Variable, Kind}'. A variable that is unset, or set to the empty
%% string, is the default and therefore not this function's business -- a default is a
%% decision somebody made on purpose, even when the somebody was whoever wrote the
%% default.
%%
%% This is a function and not a `-define', and that is not a style preference. The macro
%% form is a list literal whose body carries comment lines and whose closing bracket has
%% to agree with the preprocessor's own bracket matching; when it does not, the error is
%% reported **at the use site** -- `syntax error before: ']'`, pointing at a `?SETTINGS'
%% forty lines below the define -- which is the least locatable message Erlang emits. A
%% function has one way to be written and the compiler points at the mistake.
%%
%% `ETH_NETWORK' and `ETH_FORK` are the two settings whose values are **names** rather
%% than quantities, so their rules are not here but in `eth_fork_schedule', which holds
%% the only list of the names there is. An earlier version of this comment argued they
%% belonged outside the table because a name is not a quantity -- true, and irrelevant to
%% the defect. Both fell back to a default for a name they did not recognise:
%% `ETH_NETWORK` to `sepolia`, behind a `logger:warning` emitted from inside a function
%% called thirteen times, which is a repeating log line rather than a report; and
%% `ETH_FORK` to `cancun` with nothing at all, out of a table of twenty-four names, so
%% `ETH_FORK=shangai` produced a node running Shanghai rules that had never said so. They
%% are in the table now, their rules are still `eth_fork_schedule`'s, and there is
%% therefore one list of names and one decision about each.
settings() ->
    [{"UPSTREAM_RPC_URL", url},
     {"RPC_LISTEN_PORT", port},
     {"RPC_LISTEN_IP", ip4},
     {"RPC_MAX_BATCH", positive},
     {"RPC_RATE_LIMIT", nonneg},
     {"RPC_RATE_BURST", positive},
     {"RPC_API_KEY", nonempty},
     {"ENGINE_PORT", port},
     {"DATA_DIR", nonempty},
     {"ETH_START_BLOCK", block},
     {"SYNC_CONCURRENCY", positive},
     {"BODY_WINDOW", nonneg},
     {"CHAIN_RETENTION", positive},
     {"POLL_INTERVAL_MS", positive},
     {"SYNC_RETRY_MS", positive},
     {"MAX_REORG_DEPTH", positive},
     {"HTTP_TIMEOUT_MS", positive},
     {"SYNC_BUDGET", positive},
     {"VERIFY_HEADERS", boolean},
     {"EVM_ETH_CALL", boolean},
     {"DISCV4_ENABLED", boolean},
     {"DISCV4_PORT", port},
     {"DISCV4_BOOTNODES", enodes},
     {"RLPX_ENABLED", boolean},
     {"RLPX_PORT", port},
     {"PEER_TARGET", nonneg},
     {"PEER_DIAL_INTERVAL", positive},
     {"TX_POOL_MAX", positive},
     {"TX_POOL_PER_SENDER", positive},
     {"STATE_SYNC_ENABLED", boolean},
     {"ETH_NETWORK", network},
     {"ETH_FORK", fork}].


%% {ok, Warnings} or {error, Problems}. A problem is `{Variable, AsWritten, Why}`, and it
%% stops the node starting. A warning is the same shape and does not.
validate() ->
    Problems = lists:flatmap(fun check/1, settings()),
    Warnings = warnings(),
    case lists:usort(Problems) of
        [] -> {ok, lists:usort(Warnings)};
        Ps -> {error, Ps}
    end.

check({Var, Kind}) ->
    case os:getenv(Var) of
        false -> [];
        "" -> [];
        Raw ->
            case parse(Kind, Raw) of
                ok -> [];
                {error, Why} -> [{Var, Raw, Why}]
            end
    end.

%% Not problems, because the node is correct in each case and only the operator might
%% not have meant it. Each of these was a real configuration in this repository's own
%% history or a plausible operator mistake, and a refusal would be wrong for all three.
warnings() ->
    W = [warn_unsafe_bind(), warn_ports_collide(), warn_retention_below_body_window(),
         warn_unauthenticated_bind()],
    lists:flatten([X || X <- W, X =/= []]).

warn_unsafe_bind() ->
    case {os:getenv("RPC_LISTEN_IP"), os:getenv("ENGINE_PORT")} of
        {false, _} -> [];
        _ ->
            case bind_is_public() of
                true -> [{"RPC_LISTEN_IP", "0.0.0.0",
                          "binds JSON-RPC to every interface; the default is loopback and "
                          "exposing it needs RPC_API_KEY or a firewall, deliberately"}];
                false -> []
            end
    end.

warn_ports_collide() ->
    case {truthy("DISCV4_ENABLED"), truthy("RLPX_ENABLED")} of
        {true, true} ->
            D = os:getenv("DISCV4_PORT"), R = os:getenv("RLPX_PORT"),
            case {D, R} of
                {false, false} ->
                    [{"DISCV4_PORT", "30303",
                      "discv4 and RLPx are both enabled and both default to 30303, so "
                      "one of them will fail to bind; set the two ports apart"}];
                {D1, R1} when D1 =:= R1, D1 =/= false ->
                    [{"DISCV4_PORT", D1,
                      "discv4 and RLPx are both enabled on the same port"}];
                _ -> []
            end;
        _ -> []
    end.

warn_retention_below_body_window() ->
    case {int("CHAIN_RETENTION"), int("BODY_WINDOW")} of
        {error, _} -> [];
        {_, error} -> [];
        {R, B} when B > R ->
            [{"CHAIN_RETENTION", integer_to_list(R),
              io_lib:format("keeps ~b blocks but BODY_WINDOW asks for bodies on ~b, so "
                            "the oldest ~b of them are pruned anyway",
                            [R, B, B - R])}];
        _ -> []
    end.

warn_unauthenticated_bind() ->
    case bind_is_public() of
        true ->
            case os:getenv("RPC_API_KEY") of
                false -> warn_unsafe_bind();
                "" -> warn_unsafe_bind();
                _ -> []
            end;
        false -> []
    end.

bind_is_public() ->
    case os:getenv("RPC_LISTEN_IP") of
        false -> false;
        V -> string:trim(V) =:= "0.0.0.0"
    end.

truthy(Var) ->
    case os:getenv(Var) of
        V when is_list(V) ->
            lists:member(string:lowercase(string:trim(V)), ["true", "1", "yes"]);
        _ -> false
    end.

int(Var) ->
    case os:getenv(Var) of
        false -> error;
        V -> case string:to_integer(string:trim(V)) of
                 {N, ""} -> N;
                 _ -> error
             end
    end.

%% ---------------------------------------------------------------------------
%% Parsing. One function per kind, so the table above is the whole of what is checked
%% and adding a setting is one line rather than a rule in two places.
%% ---------------------------------------------------------------------------

parse(port, V) ->
    case int_of(V) of
        {ok, N} when N >= 1, N =< 65535 -> ok;
        {ok, N} -> {error, io_lib:format("~b is not a TCP port (1-65535)", [N])};
        error -> {error, "not a number"}
    end;
parse(positive, V) ->
    case int_of(V) of
        {ok, N} when N >= 1 -> ok;
        {ok, N} -> {error, io_lib:format("~b must be at least 1", [N])};
        error -> {error, "not a number"}
    end;
parse(nonneg, V) ->
    case int_of(V) of
        {ok, N} when N >= 0 -> ok;
        {ok, N} -> {error, io_lib:format("~b must not be negative", [N])};
        error -> {error, "not a number"}
    end;
parse(boolean, V) ->
    case lists:member(string:lowercase(string:trim(V)),
                      ["true", "false", "1", "0", "yes", "no", "on", "off"]) of
        true -> ok;
        false -> {error, "not a boolean (true/false, 1/0, yes/no, on/off)"}
    end;
parse(ip4, V) ->
    case ip4(V) of
        {ok, _} -> ok;
        error ->
            {error, "not a dotted-quad IPv4 address, all four octets 0-255"}
    end;
parse(url, V) ->
    case re:run(V, "^[A-Za-z][A-Za-z0-9+.-]*://[^/\\s]+", [{capture, none}]) of
        match -> ok;
        nomatch -> {error, "not an absolute URL (expected scheme://host[:port])"}
    end;
parse(nonempty, V) ->
    case string:trim(V) of
        "" -> {error, "empty; the empty string means the default, so setting it to \"\" "
                      "is the same as not setting it"};
        _ -> ok
    end;
parse(block, V) ->
    case string:trim(V) of
        "latest" -> ok;
        "0x" ++ Rest ->
            case Rest of
                "" -> {error, "\"0x\" with no digits"};
                _ -> case lists:all(fun(C) -> is_hex(C) end, Rest) of
                         true -> ok;
                         false -> {error, "0x-prefixed value is not hexadecimal"}
                     end
            end;
        Decimal ->
            case string:to_integer(Decimal) of
                {N, ""} when N >= 0 -> ok;
                _ -> {error, "expected \"latest\", a 0x-prefixed hex block number, or a "
                             "decimal block number"}
            end
    end;
parse(enodes, V) ->
    Bad = [string:trim(E)
           || E <- string:split(V, ",", all),
              string:trim(E) =/= "",
              not lists:prefix("enode://", string:trim(E))],
    case Bad of
        [] -> ok;
        [First | _] -> {error, io_lib:format("not an enode:// URL: ~s", [First])}
    end;
parse(network, V) -> eth_fork_schedule:validate_network(V);
parse(fork, V) -> eth_fork_schedule:validate_fork(V);
parse(Kind, _V) ->
    %% **Not** `ok'. A kind with no rule is a typo in `settings/0', and a typo that
    %% validates everything is a setting this module reports as checked and never
    %% checks -- the same shape as an accumulator that records a decision without
    %% gating the behaviour. Refusing is the honest answer, and the kind is named so
    %% the message points at the line that has to change.
    {error, io_lib:format("no rule for this kind of setting (~p)", [Kind])}.

%% Every kind `parse/2' has a clause for. `the_table_names_only_kinds_that_are_checked/
%% 0' in `eth_config_tests' asserts that the table names nothing outside this list, so
%% the list and the clauses cannot drift apart with a test passing.
kinds() ->
    [port, positive, nonneg, boolean, ip4, url, nonempty, block, enodes,
     network, fork].

%% Four dotted decimals, each 0..255, as `{A, B, C, D}'. Exported because
%% `eth_config:listen_ip/0' needs the *tuple*, not a verdict, which is the reason this is
%% not only a `parse/2' clause.
%%
%% `eth_config' used to parse the address itself, with `list_to_integer/1' and no checks,
%% so `1.999.1.1' came out as the tuple {1, 999, 1, 1} -- which `inet:parse_address/1'
%% answers `einval' for, so the malformed address reached the listener and failed there
%% instead of here. `listen_ip/0' then ranged over the **first** octet only, so between
%% them they accepted that tuple, and the fallback for `999.1.1.1' was a silent
%% substitution of loopback: an operator who asked to expose the RPC and mistyped the
%% address got an unreachable node. All three halves are fixed -- this function never
%% builds the tuple, `eth_config' holds no second implementation of the decision to
%% disagree with it, and `validate/0` reports the value as a problem so the node refuses
%% to start.
%%
%% **The error is a tag, not a value, and that is not a style choice.** A first version
%% built the octets with
%%
%%     case [octet(X) || X <- [A, B, C, D]] of
%%         [N1, N2, N3, N4] -> {ok, {N1, N2, N3, N4}};
%%         _ -> error
%%     end
%%
%% with `octet/1' answering `not_an_octet', and it was **wrong for every bad address**:
%% `[1, not_an_octet, 1, 1]' is a four-element list, so it matched `[N1, N2, N3, N4]' with
%% the error atom bound to `N2', the `_ -> error' clause was unreachable, and
%% `ip4("1.999.1.1")' answered `{ok, {1, not_an_octet, 1, 1}}' -- so `listen_ip/0'
%% returned a tuple with an **atom where an octet belongs** and `validate/0' reported the
%% address as fine. The right arity is not a check on the right *types*, which is exactly
%% what an untagged element in the list defeats. Hence `{ok, N} | error` and an explicit
%% `lists:all/2`.
ip4(Str) ->
    case string:split(string:trim(Str), ".", all) of
        [A, B, C, D] ->
            Octets = [octet(X) || X <- [A, B, C, D]],
            case lists:all(fun is_octet_result/1, Octets) of
                true -> {ok, list_to_tuple([N || {ok, N} <- Octets])};
                false -> error
            end;
        _ -> error
    end.

is_octet_result({ok, N}) when is_integer(N), N >= 0, N =< 255 -> true;
is_octet_result(_) -> false.

int_of(V) ->
    case string:to_integer(string:trim(V)) of
        {N, ""} -> {ok, N};
        _ -> error
    end.

is_hex(C) ->
    lists:member(C, "0123456789abcdefABCDEF").

octet(S) ->
    case string:to_integer(string:trim(S)) of
        {N, ""} when N >= 0, N =< 255 -> {ok, N};
        _ -> error
    end.
