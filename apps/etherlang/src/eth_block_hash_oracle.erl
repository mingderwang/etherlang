%% Block hash oracle for Phase 4: State Management.
%%
%% Maintains a list of block hashes for `eth_getBlockByHash` and
%% consensus. The oracle keeps a bounded list of recent block hashes
%% and supports historical queries by delegating to `eth_chain`.
%%
%% This is needed because post-merge, block hashes are not available
%% from the chain itself (difficulty is 0). The oracle stores them
%% as blocks are produced.
%%
%% -module(eth_block_hash_oracle).

-module(eth_block_hash_oracle).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([ add_block_hash/2,
          get_block_hash/1,
          get_block_hashes/2,
          block_hash/1,
          status/0 ]).

-record(st, {
    hashes = #{} :: map(),        %% Number => Hash
    max_size = 256 :: integer(),  %% Keep recent 256 blocks
    chain :: term()
}).

%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Chain = eth_chain,
    Head = eth_chain:head(Chain),
    Hashes = case Head of
        {Num, Hash} -> maps:put(Num, Hash, #{});
        _ -> #{}
    end,
    logger:notice("etherlang: Block hash oracle started (~p blocks)", [map_size(Hashes)]),
    {ok, #st{hashes = Hashes, chain = Chain}}.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

handle_call({add_block, Number, Hash}, _From, S) ->
    NewHashes = maps:put(Number, Hash, S#st.hashes),
    %% Prune old hashes if exceeding max_size.
    Hashes2 = prune_old(NewHashes, S#st.max_size),
    {reply, ok, S#st{hashes = Hashes2}};
handle_call({get_hash, Number}, _From, S) ->
    case maps:find(Number, S#st.hashes) of
        {ok, Hash} -> {reply, {ok, Hash}, S};
        error ->
            %% Fall back to eth_chain for historical blocks.
            case eth_chain:get_by_number(Number) of
                {ok, Hash, _} -> {reply, {ok, Hash}, S};
                _ -> {reply, not_found, S}
            end
    end;
handle_call({get_hashes, FromNum, ToNum}, _From, S) ->
    Hashes = maps:to_list(S#st.hashes),
    Selected = [{Num, Hash} || {Num, Hash} <- Hashes,
                                Num >= FromNum, Num =< ToNum],
    {reply, {ok, Selected}, S};
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

add_block_hash(Number, Hash) ->
    gen_server:call(?MODULE, {add_block, Number, Hash}).

get_block_hash(Number) ->
    gen_server:call(?MODULE, {get_hash, Number}, infinity).

get_block_hashes(FromNum, ToNum) ->
    gen_server:call(?MODULE, {get_hashes, FromNum, ToNum}, infinity).

block_hash(Number) ->
    case get_block_hash(Number) of
        {ok, Hash} -> Hash;
        not_found -> <<>>
    end.

status() ->
    gen_server:call(?MODULE, get_status, infinity).

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------

prune_old(Hashes, MaxSize) when map_size(Hashes) =< MaxSize ->
    Hashes;
prune_old(Hashes, MaxSize) ->
    Sorted = lists:sort(maps:to_list(Hashes)),
    Keep = lists:nthtail(length(Sorted) - MaxSize, Sorted),
    maps:from_list(Keep).

status(#st{hashes = Hashes}) ->
    #{
        block_count => map_size(Hashes),
        max_size => 256
    }.
