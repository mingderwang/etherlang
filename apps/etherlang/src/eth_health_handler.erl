%% -*- erlang -*-
%% `GET /health` -- whether this node is up and whether it can answer.
%%
%% **A health endpoint that cannot answer "no" is a decoration.** So this one probes the
%% components that hold the node's state and returns 503 if any of them does not answer,
%% and the probes are real `gen_server:call/3`s with a timeout rather than `is_process_alive/1`
%% checks. The distinction matters: a `gen_server` that is alive and wedged -- blocked in a
%% DETS write, or in a trie operation -- passes an `is_process_alive/1` probe and cannot
%% serve a single request. An orchestrator needs the second answer.
%%
%% What it deliberately does **not** say:
%%
%%   * It does not claim the node is in sync with the network. `eth_sync:status/1` is
%%     reported as the fact it is -- `syncing: true` with the three block numbers the
%%     JSON-RPC `eth_syncing` method already returns -- and not folded into the verdict.
%%     "Synced" is not a health property of a node that does not author blocks.
%%   * It does not call `eth_state:chain_id/0`, which fetches over RPC on first use. A
%%     health endpoint that performs a lazy network fetch turns an upstream outage into a
%%     restart loop, which is a self-inflicted outage.
%%   * It does not report a `stateRoot`, or anything else this node would have to
%%     recompute to answer. See AGENTS.md §4.1: there is no way to get a bare root out of
%%     this codebase on purpose, and a health endpoint is not the place to add one.
%%
%% It **bypasses `RPC_API_KEY` and the rate limiter**, and that is a decision with a
%% consequence. An orchestrator's probe cannot be expected to carry a bearer token, and a
%% probe that 401s is a probe that has been ignored. What it discloses is liveness, the
%% head number and hash, the pool's size and whether sync is running -- none of which is
%% an oracle: nothing here lets a caller read a balance, a storage slot or a code hash.
%% The bind default is loopback, and `RPC_LISTEN_IP=0.0.0.0` without an API key is already
%% a startup warning; this adds a second reason that combination is worth a thought.
-module(eth_health_handler).

-behaviour(cowboy_handler).

-export([init/2, report/1]).

-define(TIMEOUT, 2000).

%% `cowboy_handler:init/2` must **return** `{ok, Req, State}`; the reply itself is the
%% `Req` it hands back, not the return value. Returning `cowboy_req:reply/4`'s `ok` gives
%% `{try_clause, Req}` from `cowboy_handler:execute/2` and no response at all -- which is
%% the other thing in this module that only the real-HTTP test could find, since nothing
%% that calls `report/1' can notice a handler that never replies.
init(Req, Opts) ->
    Report = report(Opts),
    Code = status_code(maps:get(<<"status">>, Report)),
    Req1 = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>},
                             thoas:encode(Report), Req),
    {ok, Req1, undefined}.

%% 200 only if every probe answered. Not "200 unless something is clearly broken": a
%% component that did not answer is not a component this node can serve from.
%%
%% This takes the **status string**, not the report, so there is one place that decides
%% and one key that names it. The first version took the report and did
%% `maps:get(status, Report)` against a `<<"status">>` key -- an atom against a binary --
%% so `init/2' raised `{badkey, status}'` and cowboy answered **500**. It did so *only*
%% when the node was unhealthy, which is the 503 path and therefore the one that matters,
%% and every test that called `report/1' directly passed. The endpoint was 100% correct
%% and completely broken at the same time. It is caught by the one test that makes a real
%% HTTP request, and by nothing else in the module.
status_code(<<"ok">>) -> 200;
status_code(_) -> 503.

%% The report. Pure with respect to the node: it reads and reports, it changes nothing.
report(Opts) ->
    Checks = #{<<"config">> => check_config(),
               <<"chain">> => check_chain(maps:get(chain, Opts, eth_chain)),
               <<"mpt">> => check_mpt(maps:get(mpt, Opts, eth_mpt)),
               <<"sync">> => check_sync(maps:get(sync, Opts, eth_sync)),
               <<"pool">> => check_pool(maps:get(pool, Opts, eth_txpool))},
    #{<<"status">> => status(Checks),
      <<"checks">> => Checks}.

status(Checks) ->
    case lists:sort([Name || {Name, #{<<"ok">> := false}} <- maps:to_list(Checks)]) of
        [] -> <<"ok">>;
        Bad -> iolist_to_binary(["degraded: ", lists:join(",", Bad)])
    end.

%% `etherlang_app:check_config/0' is `eth_config_settings:validate/0', which reads the
%% environment and nothing else -- no process, no disk. It is here because a node that
%% booted with a configuration it refused to start is the one case where "up" and "can
%% serve" come apart, and reporting it makes that visible if it ever happens anyway.
check_config() ->
    case etherlang_app:check_config() of
        {ok, _Warnings} -> ok(#{<<"problems">> => []});
        {error, Problems} -> fail(#{<<"problems">> =>
                                        [iolist_to_binary([V, "=", G, ": ", W])
                                         || {V, G, W} <- Problems]})
    end.

check_chain(Name) ->
    probe(fun() ->
                  {HeadNum, HeadHash} = head_of(Name),
                  #{<<"head">> => eth_hex:encode_int(max(HeadNum, 0)),
                    <<"headHash">> => hash_of(HeadHash),
                    <<"highest">> => eth_hex:encode_int(max(highest_of(Name), 0)),
                    <<"blocks">> => blocks_of(Name)}
          end).

%% `eth_chain:size/1' answers the integer directly, not a map. It was read through
%% `maps:get/3' here first, which answered `{badmap, 7}' -- and the probe above turned
%% that into `{"ok": false, "error": "{badmap,7}"}` rather than a crash, which is the
%% reason to have a probe at all but is a poor way to learn that a field is an integer.
blocks_of(Name) ->
    case call(Name, size) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.

%% `head' is `undefined' before the first block is stored, and that is a normal state for
%% a node that has not synced yet, so it is reported as block 0 with a null hash rather
%% than as a failure. The node is up; it has nothing to say yet. Those are different
%% answers and the endpoint has room for both.
head_of(Name) ->
    case call(Name, head) of
        {N, Hash} -> {N, Hash};
        _ -> {0, null}
    end.

hash_of(null) -> null;
hash_of(undefined) -> null;
%% `eth_hex:encode_bytes/1`, **not** `eth_hex:encode/1`. The latter is named as if it
%% were the general encoder and is not: its only clauses are `encode(0)` and
%% `encode(Int) when is_integer(Int), Int > 0`, so a binary raises `function_clause` and a
%% negative integer does too. Found by the probe below the one it is used in, which is the
%% ordinary way these are found.
hash_of(Hash) when is_binary(Hash) -> eth_hex:encode_bytes(Hash);
hash_of(_) -> null.

highest_of(Name) ->
    case call(Name, highest) of
        N when is_integer(N) -> N;
        _ -> -1
    end.

%% `eth_mpt:size/0` is `dets:info/2` size, so this is a real probe of the store rather
%% than a restatement of "the process exists". The name comes from the options like the
%% other three, defaulting to the singleton -- which is the point of the change: hardcoding
%% it meant the one probe with no seam was the one no test could exercise without opening
%% a DETS file under the un-scoped `DATA_DIR`, which is the trap in AGENTS.md §10a.
check_mpt(Name) ->
    probe(fun() -> #{<<"accounts">> => accounts_of(Name)} end).

accounts_of(Name) ->
    case call(Name, size) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.

check_sync(Name) ->
    probe(fun() ->
                  #{<<"syncing">> => is_map(call(Name, status))}
          end).

check_pool(Name) ->
    probe(fun() ->
                  Status = call(Name, status),
                  #{<<"pending">> => maps:get(pending, Status, 0),
                    <<"queued">> => maps:get(queued, Status, 0),
                    <<"total">> => maps:get(total, Status, 0)}
          end).

%% Every probe goes through here, so "the component did not answer" has exactly one
%% implementation. Three things can happen and all three are reported rather than raised:
%% it answers, it times out, or it is not there. A crash in the handler would make a
%% health endpoint the least healthy thing on the node.
probe(Fun) ->
    try Fun() of
        Body -> ok(Body)
    catch
        exit:{timeout, _} -> fail(#{<<"error">> => <<"timeout">>});
        exit:{noproc, _} -> fail(#{<<"error">> => <<"not running">>});
        exit:Reason -> fail(#{<<"error">> => describe(exit, Reason)});
        error:Reason -> fail(#{<<"error">> => describe(error, Reason)})
    end.

call(Name, Request) ->
    gen_server:call(Name, Request, ?TIMEOUT).

ok(Body) -> maps:put(<<"ok">>, true, Body).

fail(Body) -> maps:put(<<"ok">>, false, Body).

describe(Class, {Reason, {GenServer, Call, _}})
  when Class =:= exit; GenServer =:= gen_server; Call =:= call ->
    %% `gen_server:call/3` reports its own timeout as this triple, and the name is a
    %% placeholder rather than the server that was asked, so the server asked is carried
    %% in the message instead.
    iolist_to_binary(io_lib:format("call failed: ~p", [Reason]));
describe(_Class, Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
