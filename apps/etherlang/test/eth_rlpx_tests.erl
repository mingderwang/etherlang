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

%% A frame whose 32-byte header arrives *late* and whose body never arrives at all must
%% still be reported within the budget it was given, not twice it.
%%
%% **This is the only test in the repository that can hold the framing layer to a deadline**,
%% and it needs a relay because a plain loopback pair cannot produce the shape:
%% `eth_rlpx:send_frame/4' writes the header and the body in one `gen_tcp:send', so a frame
%% is always whole by the time a socket sees it. The relay sits between the two ends and,
%% on command, holds a write for `Delay' ms, forwards only the first 32 bytes, and keeps the
%% rest. Writing the framing by hand in the test instead would be a second implementation of
%% `send_frame/4' -- a second implementation is exactly what a fixture must not be, because
%% it agrees with the code by construction and disagrees with it silently.
%%
%% **The numbers are chosen so the two readings are far apart.** `recv/3' is given 1000 ms
%% and the header is held for 800. The old code spent the header read's 800 ms and then
%% handed the *same* 1000 ms to the body read, so it returned at ~1800 ms; the code now
%% carries one absolute deadline through both reads and returns at ~1000 ms. The assertion is
%% at 1400 ms, which is 400 ms above the correct answer and 400 ms below the wrong one.
%% **An explicit 60 s, because eunit's default is 5 s and this does two secp256k1 keygens
%% plus a full handshake.** The first version timed out with nothing printed, which reads as
%% a hang and is indistinguishable from one -- and `interop_test/0` above gets away with the
%% default only because it happens to finish inside it.
split_frame_deadline_test_() ->
    {timeout, 60, fun split_frame_deadline/0}.

split_frame_deadline() ->
    PrivA = eth_secp256k1:generate_key(),
    PrivB = eth_secp256k1:generate_key(),
    IDA = eth_ecies:pubkey(PrivA),
    IDB = eth_ecies:pubkey(PrivB),
    LSock = [binary, {packet, raw}, {active, false}, {reuseaddr, true}],
    {ok, LS} = gen_tcp:listen(0, LSock),
    {ok, LPort} = inet:port(LS),
    {ok, RL} = gen_tcp:listen(0, LSock),
    {ok, RPort} = inet:port(RL),
    Parent = self(),
    spawn(fun() -> pinging_acceptor(Parent, LS, PrivB, opts(IDB)) end),
    spawn(fun() -> relay(Parent, RL, {127, 0, 0, 1}, LPort) end),
    {ok, SessA0, SockA} = eth_rlpx:dial({127, 0, 0, 1}, RPort, PrivA, IDB),
    {ok, SessA1, _HelloB} = eth_rlpx:hello(SessA0, SockA, opts(IDA)),
    %% **`acceptor_hello`, not `accepted_hello`.** Those differ by one letter and the first
    %% version of this test received the one that is never sent, so it timed out on a
    %% handshake that had completed -- with both messages sitting in the mailbox. The only
    %% reason it was found is that the timeout handler printed the mailbox, which is worth
    %% more than the assertion it was about: a receive that never matches and a receive that
    %% matches nothing look identical until you look at what is actually there.
    receive
        {acceptor_hello, _} -> ok
    after 5000 ->
        error(acceptor_timeout)
    end,
    Pump = receive {relay_ready, P} -> P after 5000 -> error(relay_never_ready) end,
    %% Arm the relay, then let the acceptor send. In this order: armed first, or the frame
    %% arrives whole and the test measures nothing -- which is the outcome that looks like a
    %% pass.
    Pump ! {split, 800},
    Parent ! ping_now,
    {T, R} = timer:tc(fun() -> eth_rlpx:recv(SessA1, SockA, 1000) end),
    %% Release whatever the relay is still holding so the acceptor can shut down cleanly.
    Pump ! release,
    ?assertEqual({error, timeout}, R),
    ?assert(T < 1400000),
    gen_tcp:close(SockA),
    gen_tcp:close(RL),
    gen_tcp:close(LS).

%% Transparent byte pump, until told to hold a write and forward only its first 32 bytes.
%%
%% The held bytes live in the process dictionary on purpose: this is a two-argument loop and
%% the split has to survive across a `recv', and a test helper that threads a third
%% accumulator through the recursion reads worse than one that says where the state is.
relay(Parent, RL, Host, Port) ->
    Opts = [binary, {packet, raw}, {active, false}],
    {ok, CSock} = gen_tcp:accept(RL, 5000),
    %% `connect' to the acceptor completes the TCP handshake; the acceptor's own
    %% `gen_tcp:accept(LS)' is what returns the far end of this socket.
    {ok, ASock} = gen_tcp:connect(Host, Port, Opts),
    Down = spawn(fun() -> pump(ASock, CSock) end),
    _ = spawn(fun() -> pump(CSock, ASock) end),
    Parent ! {relay_ready, Down},
    %% **Stay alive.** This process *owns* both sockets, and a socket's owner closing is what
    %% closes it -- so returning here tore down the connection, and the acceptor's next
    %% `eth_rlpx:ping/2' answered `{badmatch, {error, closed}}'. The pumps have their own
    %% processes; this one only holds the ports.
    receive stop -> ok end.

%% One direction. In `normal' mode it forwards whatever arrives. On `{split, Delay}' it holds
%% the next write for `Delay' ms, forwards only the first 32 bytes -- which is exactly one
%% frame header -- and parks the rest until `release'.
pump(Src, Dst) -> pump(Src, Dst, normal).

pump(Src, Dst, normal) ->
    case gen_tcp:recv(Src, 0, 200) of
        {ok, Data} when is_binary(Data) ->
            %% The split is armed *when data arrives*, which is the only moment it can
            %% apply. Checking it on a `receive ... after 0' instead makes this a busy loop
            %% that spins on a closed socket -- the first version did, and it burned a core
            %% for the length of the test.
            receive
                {split, Delay} ->
                    timer:sleep(Delay),
                    {Head, Rest} = split32(Data, 32),
                    ok = gen_tcp:send(Dst, Head),
                    put(held, Rest),
                    wait_release(Src, Dst)
            after 0 ->
                ok = gen_tcp:send(Dst, Data),
                pump(Src, Dst, normal)
            end;
        _ ->
            pump(Src, Dst, normal)
    end.

wait_release(Src, Dst) ->
    receive
        release ->
            case get(held) of
                undefined -> ok;
                Held -> ok = gen_tcp:send(Dst, Held)
            end,
            pump(Src, Dst, normal)
    after 10000 ->
        ok
    end.

%% `binary:part/3' on a short binary raises, and a frame arriving in two writes would be
%% shorter than a header. That is not a case this test produces, and pretending otherwise
%% would be a clause that exists only to be uncovered.
split32(Data, N) when byte_size(Data) >= N ->
    <<Head:N/binary, Rest/binary>> = Data,
    {Head, Rest};
split32(Data, _) ->
    {Data, <<>>}.

acceptor(Parent, LS, PrivB, OptsB) ->
    {ok, Sock} = gen_tcp:accept(LS, 5000),
    {ok, Sess} = eth_rlpx:recipient(Sock, PrivB, 5000),
    {ok, Sess1, HelloA} = eth_rlpx:hello(Sess, Sock, OptsB),
    Parent ! {acceptor_hello, HelloA},
    pong_loop(Sess1, Sock).

%% A handshake partner that **sends** on request. `acceptor/4` only ever replies to a Ping,
%% and the three existing tests use it in that role; changing it would either hang them (if
%% it waited for a `go') or change what they measure (if it sent unprompted).
pinging_acceptor(Parent, LS, PrivB, OptsB) ->
    {ok, Sock} = gen_tcp:accept(LS, 5000),
    {ok, Sess} = eth_rlpx:recipient(Sock, PrivB, 5000),
    {ok, Sess1, HelloA} = eth_rlpx:hello(Sess, Sock, OptsB),
    Parent ! {acceptor_hello, HelloA},
    receive ping_now -> ok after 10000 -> ok end,
    {ok, Sess2} = eth_rlpx:ping(Sess1, Sock),
    pong_loop(Sess2, Sock).

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
