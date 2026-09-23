-module(eth_rlpx_tests).

-include_lib("eunit/include/eunit.hrl").

opts(ID) ->
    #{node_id => ID, client_id => <<"test">>, caps => [], listen_port => 0}.

%% Full initiator<->recipient handshake, Hello exchange, and p2p Ping/Pong
%% over loopback TCP.
interop_test() ->
    PrivA = eth_secp256k1:generate_key(),
    PrivB = eth_secp256k1:generate_key(),
    IDA = eth_ecies:pubkey(PrivA),
    IDB = eth_ecies:pubkey(PrivB),
    {ok, LS} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
                                  {reuseaddr, true}]),
    {ok, Port} = inet:port(LS),
    Parent = self(),
    spawn(fun() -> acceptor(Parent, LS, PrivB, opts(IDB)) end),
    {ok, SessA0, SockA} = eth_rlpx:dial({127, 0, 0, 1}, Port, PrivA, IDB),
    %% Remote id recovered by the handshake matches the dial target.
    ?assertEqual(IDB, eth_rlpx:remote_id(SessA0)),
    {ok, SessA1, HelloB} = eth_rlpx:hello(SessA0, SockA, opts(IDA)),
    ?assertEqual(IDB, maps:get(node_id, HelloB)),
    receive
        {acceptor_hello, HelloA} ->
            ?assertEqual(IDA, maps:get(node_id, HelloA))
    after 5000 ->
        error(acceptor_timeout)
    end,
    %% Ping/Pong after snappy is on exercises compress+decompress both ways.
    {ok, _SessA2} = eth_rlpx:ping(SessA1, SockA),
    gen_tcp:close(SockA),
    gen_tcp:close(LS).

%% Garbage bytes fail header MAC verification.
mac_tamper_test() ->
    PrivA = eth_secp256k1:generate_key(),
    PrivB = eth_secp256k1:generate_key(),
    IDB = eth_ecies:pubkey(PrivB),
    {ok, LS} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
                                  {reuseaddr, true}]),
    {ok, Port} = inet:port(LS),
    Parent = self(),
    spawn(fun() -> acceptor_garbage(Parent, LS, PrivB, opts(IDB)) end),
    {ok, SessA0, SockA} = eth_rlpx:dial({127, 0, 0, 1}, Port, PrivA, IDB),
    {ok, SessA1, _} = eth_rlpx:hello(SessA0, SockA, opts(eth_ecies:pubkey(PrivA))),
    %% The acceptor sends 32 zero bytes instead of a frame: the header MAC
    %% check must reject them before any decryption.
    ?assertEqual({error, bad_header_mac},
                 eth_rlpx:recv(SessA1, SockA, 5000)),
    receive acceptor_done -> ok after 5000 -> error(acceptor_timeout) end,
    gen_tcp:close(SockA),
    gen_tcp:close(LS).

acceptor(Parent, LS, PrivB, OptsB) ->
    {ok, Sock} = gen_tcp:accept(LS, 5000),
    {ok, Sess} = eth_rlpx:recipient(Sock, PrivB, 5000),
    {ok, Sess1, HelloA} = eth_rlpx:hello(Sess, Sock, OptsB),
    Parent ! {acceptor_hello, HelloA},
    pong_loop(Sess1, Sock).

pong_loop(Sess, Sock) ->
    case eth_rlpx:recv(Sess, Sock, 8000) of
        {ok, 2, _, S1} ->
            {ok, S2} = eth_rlpx:send(S1, Sock, 3, eth_rlp:encode([])),
            pong_loop(S2, Sock);
        {ok, _, _, S1} ->
            pong_loop(S1, Sock);
        _ ->
            (try gen_tcp:close(Sock) catch _:__ -> ok end),
            ok
    end.

acceptor_garbage(Parent, LS, PrivB, OptsB) ->
    {ok, Sock} = gen_tcp:accept(LS, 5000),
    {ok, Sess} = eth_rlpx:recipient(Sock, PrivB, 5000),
    {ok, _Sess1, _} = eth_rlpx:hello(Sess, Sock, OptsB),
    ok = gen_tcp:send(Sock, <<0:256>>),
    timer:sleep(500),
    (try gen_tcp:close(Sock) catch _:__ -> ok end),
    Parent ! acceptor_done.
