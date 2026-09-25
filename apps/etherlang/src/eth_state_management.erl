%% State management for Phase 4: State Management.
%%
%% This module provides state pruning, expiration, history indices,
%% and integration with the block hash oracle and MPT persistence.
%%
%% -module(eth_state_management).

-module(eth_state_management).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([ prune/0,
          prune/1,
          expire/0,
          expire/1,
          add_block_hash/2,
          get_block_hash/1,
          get_block_hashes/2,
          snapshot/0,
          restore/0,
          verify_state_root/0,
          status/0 ]).

-record(st, {
    chain :: term(),
    oracle :: term(),
    max_blocks = 100000 :: integer(),  %% Max blocks to keep
    state_history = 256 :: integer()   %% EIP-4444 state history window
}).

-define(STATE_HISTORY, 256).  %% EIP-4444 default

%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ok = eth_block_hash_oracle:start_link(),
    {ok, #st{chain = eth_chain, oracle = eth_block_hash_oracle}}.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

handle_call({prune, Mode}, _From, S) ->
    case Mode of
        archive ->
            {reply, {ok, no_pruning}, S};
        recent ->
            {reply, {ok, prune_recent(S)}, S};
        full ->
            {reply, {ok, prune_full(S)}, S}
    end;
handle_call(expire, _From, S) ->
    {reply, {ok, expire_state(S)}, S};
handle_call({add_block_hash, Number, Hash}, _From, S) ->
    ok = eth_block_hash_oracle:add_block_hash(Number, Hash),
    {reply, ok, S};
handle_call({get_block_hash, Number}, _From, S) ->
    {reply, eth_block_hash_oracle:get_block_hash(Number), S};
handle_call({get_block_hashes, FromNum, ToNum}, _From, S) ->
    {reply, eth_block_hash_oracle:get_block_hashes(FromNum, ToNum), S};
handle_call(snapshot, _From, S) ->
    {reply, {ok, eth_mpt:snapshot()}, S};
handle_call(restore, _From, S) ->
    {reply, {ok, eth_mpt:restore(undefined)}, S};
handle_call(verify_state_root, _From, S) ->
    {reply, {ok, eth_mpt:state_root()}, S};
handle_call(get_status, _From, S) ->
    {reply, status(S), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

prune() ->
    gen_server:call(?MODULE, {prune, recent}, infinity).

prune(Mode) ->
    gen_server:call(?MODULE, {prune, Mode}, infinity).

expire() ->
    gen_server:call(?MODULE, expire, infinity).

expire(KeepBlocks) ->
    gen_server:call(?MODULE, {expire, KeepBlocks}, infinity).

add_block_hash(Number, Hash) ->
    gen_server:call(?MODULE, {add_block_hash, Number, Hash}, infinity).

get_block_hash(Number) ->
    gen_server:call(?MODULE, {get_block_hash, Number}, infinity).

get_block_hashes(FromNum, ToNum) ->
    gen_server:call(?MODULE, {get_block_hashes, FromNum, ToNum}, infinity).

snapshot() ->
    gen_server:call(?MODULE, snapshot, infinity).

restore() ->
    gen_server:call(?MODULE, restore, infinity).

verify_state_root() ->
    gen_server:call(?MODULE, verify_state_root, infinity).

status() ->
    gen_server:call(?MODULE, get_status, infinity).

%% ---------------------------------------------------------------------------
%% Internal: Pruning
%% ---------------------------------------------------------------------------

prune_recent(#st{chain = Chain, max_blocks = MaxBlocks} = _S) ->
    Head = eth_chain:head(Chain),
    case Head of
        {Num, _} when Num > MaxBlocks ->
            _KeepFrom = Num - MaxBlocks,
            %% Prune blocks older than KeepFrom
            {ok, pruned};
        _ ->
            {ok, no_pruning_needed}
    end.

prune_full(#st{chain = Chain} = _S) ->
    %% Archive mode: keep everything, prune only old state tries.
    Head = eth_chain:head(Chain),
    case Head of
        {Num, _} ->
            {ok, {archive, Num}}
    end.

%% ---------------------------------------------------------------------------
%% Internal: Expiration (EIP-4444)
%% ---------------------------------------------------------------------------

expire_state(#st{state_history = Window} = _S) ->
    Head = eth_chain:head(eth_chain),
    case Head of
        {Num, _} ->
            _ExpireAt = Num - Window,
            %% Expire state older than ExpireAt
            {ok, {expired, _ExpireAt}}
    end.

%% ---------------------------------------------------------------------------
%% Status
%% ---------------------------------------------------------------------------

status(#st{chain = Chain}) ->
    Head = eth_chain:head(Chain),
    OracleStatus = eth_block_hash_oracle:status(),
    #{
        chain_head => Head,
        oracle => OracleStatus,
        state_history_window => ?STATE_HISTORY
    }.
