%% -*- erlang -*-
%% A gen_server that answers a fixed list of `handle_call' requests, and one that wedges.
%%
%% Two reasons this is a module and not a `gen_server' started inline from the test: a
%% test module that is also a `gen_server' has to export `init/1' and `handle_call/3' and
%% declare the behaviour, which is noise in a file whose subject is HTTP status codes;
%% and the "answers once then never answers" case wants a server that is *alive* and
%% *stuck*, which is the whole point of it and is awkward to express as a parameter.
-module(eth_health_fake).

-behaviour(gen_server).

-export([start/2, start_wedged/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

%% Answers only the requests in `Clauses'; anything else is `{error, unknown_call}', which
%% is what a probe of something this fake is not standing in for should see.
start(Name, Clauses) ->
    {ok, _} = gen_server:start_link({local, Name}, ?MODULE, {clauses, Clauses}, []),
    Name.

%% Answers `head' once and then blocks inside every later call. The process stays alive
%% throughout, so an `is_process_alive/1` probe reports it healthy while the node cannot
%% answer a single request.
start_wedged(Name) ->
    {ok, _} = gen_server:start_link({local, Name}, ?MODULE, wedged, []),
    Name.

init({clauses, Clauses}) -> {ok, {clauses, Clauses}};
init(wedged) -> {ok, wedged}.

handle_call(Req, _From, {clauses, Clauses} = S) ->
    case lists:keyfind(Req, 1, Clauses) of
        {Req, Value} -> {reply, Value, S};
        false -> {reply, {error, unknown_call}, S}
    end;
handle_call(head, _From, wedged = S) ->
    {reply, {1, <<16#aa, 16#bb, 16#cc>>}, S};
handle_call(_Req, _From, S) ->
    receive after infinity -> ok end,
    S.

handle_cast(_Msg, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.
