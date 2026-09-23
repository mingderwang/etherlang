-module(eth_peer_conn).
-behaviour(gen_server).

%% One RLPx peer connection: owns its passive socket, runs the handshake in
%% init, exchanges Hellos, then polls for inbound p2p messages (answers Ping
%% with Pong) and sends periodic Pings. Any framing/auth failure stops the
%% process; the eth_peer manager drops it via monitor.

-export([start_initiator/3, start_recipient/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(PING_MS, 15000).
-define(POLL_MS, 1000).
-define(IDLE_TIMEOUT_MS, 120000).

-record(st, {sock,
             sess,
             manager,
             hello,
             last_in}).

%% Args: #{privkey, remote_id, node_id, client_id, caps, listen_port}.
start_initiator(Manager, {Host, Port}, Args) ->
    gen_server:start_link(?MODULE, {initiator, Manager, Host, Port, Args}, []).

%% Args: same as above minus remote_id; Sock is the accepted socket.
start_recipient(Manager, Sock, Args) ->
    gen_server:start_link(?MODULE, {recipient, Manager, Sock, Args}, []).

init({initiator, Manager, Host, Port, Args}) ->
    #{privkey := Priv, remote_id := RemoteID} = Args,
    case gen_tcp:connect(Host, Port,
                         [binary, {packet, raw}, {active, false},
                          {nodelay, true}, {send_timeout, 10000}], 10000) of
        {ok, Sock} ->
            case eth_rlpx:initiator(Sock, Priv, RemoteID, 10000) of
                {ok, Sess} -> finish_init(Manager, Sock, Args, Sess);
                {error, Reason} -> {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end;
init({recipient, Manager, Sock, Args}) ->
    #{privkey := Priv} = Args,
    case eth_rlpx:recipient(Sock, Priv, 10000) of
        {ok, Sess} -> finish_init(Manager, Sock, Args, Sess);
        {error, Reason} -> {stop, Reason}
    end.

finish_init(Manager, Sock, Args, Sess) ->
    case eth_rlpx:hello(Sess, Sock, Args) of
        {ok, Sess1, Hello} ->
            erlang:send_after(?POLL_MS, self(), poll),
            erlang:send_after(?PING_MS, self(), ping),
            Manager ! {peer_up, self(), eth_rlpx:remote_id(Sess1), Hello},
            {ok, #st{sock = Sock, sess = Sess1, manager = Manager,
                     hello = Hello,
                     last_in = erlang:monotonic_time(millisecond)}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(status, _From, S) ->
    {reply, #{remote => eth_rlpx:remote_id(S#st.sess),
              hello => S#st.hello,
              last_in_ms_ago => erlang:monotonic_time(millisecond) - S#st.last_in}, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(poll, S) ->
    case eth_rlpx:recv(S#st.sess, S#st.sock, ?POLL_MS) of
        {ok, Code, Data, Sess1} ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            case handle_msg(Code, Data, S1) of
                {ok, S2} ->
                    check_idle(reschedule_poll(S2));
                {stop, Reason} ->
                    {stop, Reason, S1}
            end;
        {error, timeout} ->
            check_idle(reschedule_poll(S));
        {error, closed} ->
            {stop, normal, S};
        {error, Reason} ->
            {stop, Reason, S}
    end;
handle_info(ping, S) ->
    erlang:send_after(?PING_MS, self(), ping),
    case eth_rlpx:send(S#st.sess, S#st.sock, 2, eth_rlp:encode([])) of
        {ok, Sess1} -> {noreply, S#st{sess = Sess1}};
        {error, Reason} -> {stop, Reason, S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    (try gen_tcp:close(S#st.sock) catch _:_ -> ok end),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------

reschedule_poll(S) ->
    erlang:send_after(?POLL_MS, self(), poll),
    S.

check_idle(S) ->
    case erlang:monotonic_time(millisecond) - S#st.last_in > ?IDLE_TIMEOUT_MS of
        true -> {stop, idle, S};
        false -> {noreply, S}
    end.

%% p2p messages: 0x01 disconnect, 0x02 ping, 0x03 pong. No shared caps yet,
%% so anything else is ignored.
handle_msg(1, _Data, _S) ->
    {stop, remote_disconnect};
handle_msg(2, _Data, S) ->
    case eth_rlpx:send(S#st.sess, S#st.sock, 3, eth_rlp:encode([])) of
        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
        {error, Reason} -> {stop, Reason}
    end;
handle_msg(3, _Data, S) ->
    {ok, S};
handle_msg(_Code, _Data, S) ->
    {ok, S}.
