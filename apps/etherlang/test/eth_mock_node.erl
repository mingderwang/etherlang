-module(eth_mock_node).
-behaviour(gen_server).

%% An in-process mock Ethereum JSON-RPC node used by the test-suite. Serves a
%% configurable canonical chain over cowboy and answers a small set of methods
%% deterministically.

-export([start_link/1, url/1, port/1,
         set_chain/2, extend/3, fork_at/4, chain/1,
         set_finalized/2, finalized/1, handle_rpc/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {name, port, chain = [], finalized = undefined}).

start_link(Name) when is_atom(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, Name, []).

url(Name) ->
    "http://127.0.0.1:" ++ integer_to_list(port(Name)).

port(Name) -> gen_server:call(Name, port).

set_chain(Name, Blocks) -> gen_server:cast(Name, {set_chain, Blocks}).

extend(Name, Count, Salt) -> gen_server:cast(Name, {extend, Count, Salt}).

%% Replace the chain from block At+1 onwards with Count fresh blocks (fork).
fork_at(Name, At, Count, Salt) when At >= 0 ->
    gen_server:cast(Name, {fork_at, At, Count, Salt}).

chain(Name) -> gen_server:call(Name, chain).

%% Advertise a finalized checkpoint (used by finality tests).
set_finalized(Name, Num) -> gen_server:cast(Name, {set_finalized, Num}).

finalized(Name) -> gen_server:call(Name, finalized).

%% Handled from the cowboy handler (eth_mock_http).
handle_rpc(Name, Method, Params) ->
    gen_server:call(Name, {rpc, Method, Params}).

init(Name) ->
    Port = eth_test_util:free_port(),
    Dispatch = cowboy_router:compile([{'_', [{"/", eth_mock_http, #{name => Name}}]}]),
    {ok, _} = cowboy:start_clear(Name,
                                 [{port, Port}, {ip, {127, 0, 0, 1}}],
                                 #{env => #{dispatch => Dispatch}}),
    {ok, #st{name = Name, port = Port}}.

handle_call(port, _From, S) -> {reply, S#st.port, S};

handle_call(chain, _From, S) -> {reply, S#st.chain, S};

handle_call(finalized, _From, S) -> {reply, S#st.finalized, S};

handle_call({rpc, Method, Params}, _From, S) ->
    {reply, do_rpc(S, Method, Params), S};

handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast({set_chain, Blocks}, S) -> {noreply, S#st{chain = Blocks}};

handle_cast({set_finalized, Num}, S) -> {noreply, S#st{finalized = Num}};

handle_cast({extend, Count, Salt}, S) ->
    {Parent, Blocks} = eth_test_util:make_blocks(length(S#st.chain), Count,
                                                 last_hash(S#st.chain), Salt),
    _ = Parent,
    {noreply, S#st{chain = S#st.chain ++ Blocks}};

handle_cast({fork_at, At, Count, Salt}, S) ->
    Prefix = lists:sublist(S#st.chain, At + 1),
    Parent = case Prefix of
                 [] -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>;
                 _ -> maps:get(<<"hash">>, lists:nth(At + 1, Prefix))
             end,
    {_P, NewBlocks} = eth_test_util:make_blocks(At + 1, Count, Parent, Salt),
    {noreply, S#st{chain = Prefix ++ NewBlocks}};

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #st{name = Name}) ->
    _ = try cowboy:stop_listener(Name) catch _:_ -> ok end,
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------

last_hash([]) -> <<"0x0000000000000000000000000000000000000000000000000000000000000000">>;
last_hash(Chain) -> maps:get(<<"hash">>, lists:last(Chain)).

do_rpc(S, <<"eth_blockNumber">>, _Params) ->
    case S#st.chain of
        [] -> {ok, <<"0x0">>};
        C -> {ok, eth_hex:encode_int(length(C) - 1)}
    end;
do_rpc(S, <<"eth_getBlockByNumber">>, [Tag, Full])
  when Tag =:= <<"latest">>; Tag =:= <<"pending">>; Tag =:= <<"earliest">>;
       Tag =:= <<"finalized">>; Tag =:= <<"safe">> ->
    case tag_number(S, Tag) of
        undefined -> {ok, null};
        Num -> block_at(S, Num, Full)
    end;
do_rpc(S, <<"eth_getBlockByNumber">>, [NumHex, Full]) when is_binary(NumHex) ->
    block_at(S, eth_hex:decode(NumHex), Full);
do_rpc(S, <<"eth_getBlockByHash">>, [HashHex, Full]) ->
    case lists:keyfind(HashHex, 1, [{maps:get(<<"hash">>, B), B} || B <- S#st.chain]) of
        false -> {ok, null};
        {_, Block} -> {ok, render(Block, Full)}
    end;
do_rpc(_S, <<"eth_getBalance">>, _Params) ->
    {ok, <<"0xde0b6b3a7640000">>};
do_rpc(_S, <<"eth_chainId">>, _Params) ->
    {ok, <<"0xaa36a7">>};
do_rpc(_S, <<"web3_clientVersion">>, _Params) ->
    {ok, <<"mock-node/1.0">>};
do_rpc(_S, Method, _Params) ->
    {error, {rpc_error, #{<<"code">> => -32601,
                          <<"message">> => <<"method not found: ", Method/binary>>}}}.

indexed(Chain) ->
    [{Num, B} || {Num, B} <- lists:zip(lists:seq(0, length(Chain) - 1), Chain)].

tag_number(#st{chain = []}, _Tag) -> undefined;
tag_number(S, Tag) when Tag =:= <<"latest">>; Tag =:= <<"pending">> ->
    length(S#st.chain) - 1;
tag_number(_S, <<"earliest">>) -> 0;
tag_number(S, Tag) when Tag =:= <<"finalized">>; Tag =:= <<"safe">> ->
    S#st.finalized.

block_at(S, Num, Full) ->
    case lists:keyfind(Num, 1, indexed(S#st.chain)) of
        false -> {ok, null};
        {_, Block} -> {ok, render(Block, Full)}
    end.

render(Block, true) ->
    Block;
render(Block, false) ->
    Block#{<<"transactions">> =>
               [maps:get(<<"hash">>, Tx) || Tx <- maps:get(<<"transactions">>, Block)]}.