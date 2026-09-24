-module(eth_peer_conn).
-behaviour(gen_server).

%% One RLPx peer connection: owns its passive socket, runs the handshake in
%% init, exchanges Hellos, then polls for inbound p2p messages (answers Ping
%% with Pong) and sends periodic Pings. Any framing/auth failure stops the
%% process; the eth_peer manager drops it via monitor.

-export([start_initiator/3, start_recipient/3]).
-export([start_initiator_unlinked/3, start_recipient_unlinked/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(PING_MS, 15000).
-define(POLL_MS, 1000).
-define(IDLE_TIMEOUT_MS, 120000).

-record(st, {sock,
             sess,
             manager,
             hello,
             eth,
             chain,
             pool,
             store,
             fetching = false,
             last_in}).

%% Args: #{privkey, remote_id, node_id, client_id, caps, listen_port,
%%         chain}. The _link variants link to the caller (tests); the
%% plain variants are for the manager, which monitors instead so a
%% crashing handshake cannot take the manager down with it.
start_initiator(Manager, {Host, Port}, Args) ->
    gen_server:start_link(?MODULE, {initiator, Manager, Host, Port, Args}, []).

start_initiator_unlinked(Manager, {Host, Port}, Args) ->
    gen_server:start(?MODULE, {initiator, Manager, Host, Port, Args}, []).

%% Args: same as above minus remote_id; Sock is the accepted socket.
start_recipient(Manager, Sock, Args) ->
    gen_server:start_link(?MODULE, {recipient, Manager, Sock, Args}, []).

start_recipient_unlinked(Manager, Sock, Args) ->
    gen_server:start(?MODULE, {recipient, Manager, Sock, Args}, []).

init({initiator, Manager, Host, Port, Args}) ->
    #{privkey := Priv, remote_id := RemoteID} = Args,
    case gen_tcp:connect(Host, Port,
                         [binary, {packet, raw}, {active, false},
                          {nodelay, true}, {send_timeout, 10000}], 10000) of
        {ok, Sock} ->
            case eth_rlpx:initiator(Sock, Priv, RemoteID, 10000) of
                {ok, Sess} -> finish_init(Manager, Sock, Args, Sess);
                {error, Reason} ->
                    logger:notice("etherlang: rlpx outbound handshake failed (~p)", [Reason]),
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end;
init({recipient, Manager, Sock, Args}) ->
    #{privkey := Priv} = Args,
    case eth_rlpx:recipient(Sock, Priv, 10000) of
        {ok, Sess} -> finish_init(Manager, Sock, Args, Sess);
        {error, Reason} ->
            logger:notice("etherlang: rlpx inbound handshake failed (~p)", [Reason]),
            {stop, Reason}
    end.

finish_init(Manager, Sock, Args, Sess) ->
    case eth_rlpx:hello(Sess, Sock, Args) of
        {ok, Sess1, Hello} ->
            S = #st{sock = Sock, sess = Sess1, manager = Manager,
                    hello = Hello, eth = undefined,
                    chain = maps:get(chain, Args, eth_chain),
                    pool = maps:get(pool, Args, eth_txpool),
                    store = maps:get(store, Args, eth_statestore),
                    last_in = erlang:monotonic_time(millisecond)},
            case maybe_eth(S, Args, Hello) of
                {ok, S1} ->
                    erlang:send_after(?POLL_MS, self(), poll),
                    erlang:send_after(?PING_MS, self(), ping),
                    Manager ! {peer_up, self(), eth_rlpx:remote_id(Sess1), Hello},
                    {ok, S1};
                {error, Reason} ->
                    logger:notice("etherlang: rlpx eth handshake failed (~p)", [Reason]),
                    {stop, Reason}
            end;
        {error, Reason} ->
            logger:notice("etherlang: rlpx hello failed (~p)", [Reason]),
            {stop, Reason}
    end.

%% eth capability handshake after Hello: negotiate, send our Status, await
%% and check theirs. No shared eth → stay p2p-only.
maybe_eth(S, _Args, Hello) ->
    Caps = eth_eth:negotiate_caps(eth_eth:caps(), maps:get(caps, Hello, [])),
    case maps:find(eth, Caps) of
        error ->
            {ok, S};
        {ok, Neg} ->
            case eth_eth:status_data(S#st.chain) of
                {error, _} = E ->
                    E;
                {ok, Our} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       eth_eth:msg_status(Neg),
                                       eth_rlp:encode(eth_eth:encode_status(Our))) of
                        {ok, Sess1} ->
                            await_status(S#st{sess = Sess1}, Neg, Our,
                                         maps:find(snap, Caps));
                        {error, _} = E ->
                            E
                    end
            end
    end.

await_status(S, #{base := Base} = Neg, Our, SnapOpt) ->
    case eth_rlpx:recv(S#st.sess, S#st.sock, 10000) of
        {ok, Code, Data, Sess1} when Code =:= Base ->
            case eth_eth:decode_status_bin(Data) of
                {ok, Their} ->
                    case eth_eth:check_status(Our, Their) of
                        ok ->
                            Eth = case SnapOpt of
                                      {ok, Snap} -> Neg#{status => Their,
                                                         snap => Snap};
                                      error -> Neg#{status => Their}
                                  end,
                            {ok, S#st{sess = Sess1, eth = Eth}};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        {ok, _, _, _} ->
            {error, expected_status};
        {error, _} = E ->
            E
    end.

handle_call(status, _From, S) ->
    Base = #{remote => eth_rlpx:remote_id(S#st.sess),
             hello => S#st.hello,
             eth => eth_ready(S),
             last_in_ms_ago => erlang:monotonic_time(millisecond) - S#st.last_in},
    {reply, Base, S};
handle_call({get_headers, Ref, Max, Skip, Reverse}, _From, S) ->
    case S#st.eth of
        undefined ->
            {reply, {error, no_eth}, S};
        #{base := Base} ->
            %% Suspend the poll loop while the blocking fetch owns recv.
            Req = eth_eth:encode_get_headers(Ref, Max, Skip, Reverse),
            Verify = fun(Term) -> eth_eth:verify_chain(Term, not Reverse, to_skip(Skip)) end,
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + 3,
                                        eth_rlp:encode(Req), Base + 4,
                                        fun eth_eth:decode_headers_bin/1, Verify),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2}
    end;
handle_call({get_bodies, Hashes}, _From, S) ->
    case S#st.eth of
        undefined ->
            {reply, {error, no_eth}, S};
        #{base := Base} ->
            Req = eth_eth:encode_get_bodies(Hashes),
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + 5,
                                        eth_rlp:encode(Req), Base + 6,
                                        fun eth_eth:decode_bodies_bin/1,
                                        fun(_) -> ok end),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2}
    end;
handle_call({get_receipts, Hashes}, _From, S) ->
    case S#st.eth of
        undefined ->
            {reply, {error, no_eth}, S};
        #{base := Base} ->
            Req = eth_eth:encode_get_receipts(Hashes),
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + 15,
                                        eth_rlp:encode(Req), Base + 16,
                                        fun eth_eth:decode_receipts_bin/1,
                                        fun(_) -> ok end),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2}
    end;
handle_call({snap_account_range, Root, Origin, Limit}, _From, S) ->
    snap_call(S, 0, 1,
              eth_rlp:encode(eth_snap:encode_account_req(Root, Origin, Limit)));
handle_call({snap_storage_range, Root, Account, Origin, Limit}, _From, S) ->
    snap_call(S, 2, 3,
              eth_rlp:encode(
                eth_snap:encode_storage_req(Root, Account, Origin, Limit)));
handle_call({snap_bytecodes, Hashes}, _From, S) ->
    snap_call(S, 4, 5,
              eth_rlp:encode(eth_snap:encode_bytecodes_req(Hashes)));
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast({graceful_stop, Reason}, S) ->
    %% Spec-friendly trim: send Disconnect, give the peer 2s, then stop.
    _ = eth_rlpx:send(S#st.sess, S#st.sock, 1, eth_rlp:encode([Reason])),
    erlang:send_after(2000, self(), graceful_timeout),
    {noreply, S};
handle_cast({broadcast_hashes, Hashes}, S) ->
    case S#st.eth of
        #{base := Base} ->
            case eth_rlpx:send(S#st.sess, S#st.sock, Base + 8,
                               eth_rlp:encode(eth_eth:encode_hashes(Hashes))) of
                {ok, Sess1} -> {noreply, S#st{sess = Sess1}};
                {error, Reason} -> {stop, Reason, S}
            end;
        _ ->
            {noreply, S}
    end;
handle_cast(_Msg, S) -> {noreply, S}.

handle_info(poll, #st{fetching = true} = S) ->
    %% A get_headers call owns recv right now; skip this round.
    erlang:send_after(?POLL_MS, self(), poll),
    {noreply, S};
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
handle_info(graceful_timeout, S) ->
    {stop, normal, S};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(Reason, S) ->
    case Reason of
        normal -> ok;
        shutdown -> ok;
        _ -> logger:notice("etherlang: rlpx conn terminating (~p) eth=~p",
                           [Reason, S#st.eth =/= undefined])
    end,
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

%% p2p messages: 0x01 disconnect, 0x02 ping, 0x03 pong. eth messages
%% (when negotiated) are matched first: GetBlockHeaders is served from the
%% local chain; anything else without a shared capability is ignored.
handle_msg(1, _Data, _S) ->
    {stop, remote_disconnect};
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 3 ->
    serve_headers_req(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 5 ->
    serve_bodies_req(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 15 ->
    serve_receipts_req(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 8 ->
    handle_pooled_hashes(Data, S);
handle_msg(Code, Data, #st{eth = #{base := Base}} = S)
  when Code =:= Base + 9 ->
    serve_pooled(Data, S);
handle_msg(Code, Data, #st{eth = #{snap := Snap}} = S) ->
    Base = maps:get(base, Snap),
    if Code =:= Base + 0 -> serve_account_range(Data, S, Snap);
       Code =:= Base + 2 -> serve_storage_range(Data, S, Snap);
       Code =:= Base + 4 -> serve_bytecodes(Data, S, Snap);
       true -> {ok, S}
    end;
handle_msg(2, _Data, S) ->
    case eth_rlpx:send(S#st.sess, S#st.sock, 3, eth_rlp:encode([])) of
        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
        {error, Reason} -> {stop, Reason}
    end;
handle_msg(3, _Data, S) ->
    {ok, S};
handle_msg(_Code, _Data, S) ->
    {ok, S}.

serve_headers_req(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_get_headers_bin(Data) of
        {ok, Ref, Max, Skip, Reverse} ->
            case eth_eth:serve_headers(S#st.chain, Ref, Max, Skip, Reverse) of
                {ok, Headers} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       Base + 4, eth_rlp:encode(Headers)) of
                        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                        {error, Reason} -> {stop, Reason}
                    end;
                {error, _} ->
                    {ok, S}
            end;
        {error, _} ->
            {ok, S}
    end.

serve_bodies_req(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_get_bodies_bin(Data) of
        {ok, Hashes} ->
            case eth_eth:serve_bodies(S#st.chain, Hashes) of
                {ok, Bodies} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       Base + 6, eth_rlp:encode(Bodies)) of
                        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                        {error, Reason} -> {stop, Reason}
                    end;
                {error, _} ->
                    {ok, S}
            end;
        {error, _} ->
            {ok, S}
    end.

%% Snap serving from the leaf store. Proofs are empty: the store keeps
%% leaves, not inner trie nodes, so strict requesters will reject these
%% ranges (documented; full proof serving needs inner-node retention).
serve_account_range(Data, S, Snap) ->
    case eth_snap:decode_account_req_bin(Data) of
        {ok, _Root, Origin, Limit} ->
            {ok, Items} = store_account_range(S, Origin, Limit),
            Reply = [[H || {H, _} <- Items], [A || {_, A} <- Items], []],
            send_snap(S, Snap, 1, Reply);
        {error, _} ->
            {ok, S}
    end.

serve_storage_range(Data, S, Snap) ->
    case eth_snap:decode_storage_req_bin(Data) of
        {ok, _Root, Account, Origin, Limit} ->
            {ok, Items} = store_storage_range(S, Account, Origin, Limit),
            Reply = [[H || {H, _} <- Items], [V || {_, V} <- Items], []],
            send_snap(S, Snap, 3, Reply);
        {error, _} ->
            {ok, S}
    end.

serve_bytecodes(Data, S, Snap) ->
    case eth_snap:decode_bytecodes_bin(Data) of
        {ok, Codes} ->
            Reply = [store_code(S, H) || H <- Codes],
            send_snap(S, Snap, 5, Reply);
        {error, _} ->
            {ok, S}
    end.

send_snap(S, Snap, Offset, Term) ->
    Code = maps:get(base, Snap) + Offset,
    case eth_rlpx:send(S#st.sess, S#st.sock, Code, eth_rlp:encode(Term)) of
        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
        {error, Reason} -> {stop, Reason, S}
    end.

store_account_range(S, Origin, Limit) ->
    Store = store_name(S),
    try eth_statestore:account_range(Store, Origin, Limit, 131072) of
        {ok, Items} -> {ok, Items}
    catch _:_ ->
        {ok, []}
    end.

store_storage_range(S, Account, Origin, Limit) ->
    Store = store_name(S),
    try eth_statestore:storage_range(Store, Account, Origin, Limit, 131072) of
        {ok, Items} -> {ok, Items}
    catch _:_ ->
        {ok, []}
    end.

store_code(S, H) ->
    Store = store_name(S),
    case try eth_statestore:get_code(Store, H) catch _:_ -> not_found end of
        {ok, Code} -> Code;
        _ -> <<>>
    end.

store_name(S) ->
    case S#st.store of
        undefined -> eth_statestore;
        Name -> Name
    end.

serve_receipts_req(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_get_receipts_bin(Data) of
        {ok, Hashes} ->
            case eth_eth:serve_receipts(S#st.chain, Hashes) of
                {ok, Receipts} ->
                    case eth_rlpx:send(S#st.sess, S#st.sock,
                                       Base + 16, eth_rlp:encode(Receipts)) of
                        {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                        {error, Reason} -> {stop, Reason}
                    end;
                {error, _} ->
                    {ok, S}
            end;
        {error, _} ->
            {ok, S}
    end.

%% Inbound pooled-tx announcements: fetch the unknown ones and ingest
%% them into the pool (validation inside). Best-effort; failures drop.
handle_pooled_hashes(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_hashes_bin(Data) of
        {ok, Hashes} ->
            Wanted = [H || H <- Hashes, not pool_has(S, H)],
            case Wanted of
                [] ->
                    {ok, S};
                _ ->
                    Req = eth_rlp:encode(
                            eth_eth:encode_hashes(lists:sublist(Wanted, 128))),
                    case eth_rlpx:send(S#st.sess, S#st.sock, Base + 9, Req) of
                        {ok, Sess1} ->
                            await_pooled(S#st{sess = Sess1}, Base);
                        {error, Reason} ->
                            {stop, Reason, S}
                    end
            end;
        {error, _} ->
            {ok, S}
    end.

await_pooled(S, Base) ->
    case eth_rlpx:recv(S#st.sess, S#st.sock, 10000) of
        {ok, Code, Data, Sess1} when Code =:= Base + 10 ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            case eth_eth:decode_pooled_bin(Data) of
                {ok, Txs} ->
                    lists:foreach(fun(T) -> ingest_pooled(S1, T) end, Txs),
                    {ok, S1};
                {error, _} ->
                    {ok, S1}
            end;
        {ok, _, _, Sess1} ->
            {ok, S#st{sess = Sess1}};
        {error, timeout} ->
            {ok, S};
        {error, Reason} ->
            {stop, Reason, S}
    end.

ingest_pooled(S, T) ->
    Bin = case T of
              B when is_binary(B) -> B;
              L when is_list(L) -> eth_rlp:encode(L)
          end,
    case (try eth_txpool:add_raw(pool_name(S), Bin) catch _:_ -> {error, no_pool} end) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

pool_has(S, H) ->
    Hex = <<"0x", (string:lowercase(binary:encode_hex(H)))/binary>>,
    try eth_txpool:has(pool_name(S), Hex)
    catch _:_ -> true
    end.

pool_name(S) ->
    case S#st.pool of
        undefined -> eth_txpool;
        Name -> Name
    end.

%% Serve our pooled transactions by hash (empty element when unknown).
serve_pooled(Data, S) ->
    #{base := Base} = S#st.eth,
    case eth_eth:decode_hashes_bin(Data) of
        {ok, Hashes} ->
            Txs = [pooled_term(S, H) || H <- Hashes],
            case eth_rlpx:send(S#st.sess, S#st.sock, Base + 10,
                               eth_rlp:encode(Txs)) of
                {ok, Sess1} -> {ok, S#st{sess = Sess1}};
                {error, Reason} -> {stop, Reason, S}
            end;
        {error, _} ->
            {ok, S}
    end.

pooled_term(S, H) ->
    Hex = <<"0x", (string:lowercase(binary:encode_hex(H)))/binary>>,
    case try eth_txpool:get(pool_name(S), Hex) catch _:_ -> not_found end of
        {ok, #{tx := Tx}} ->
            case eth_tx:to_rlp(Tx) of
                {ok, <<T, _/binary>> = Enc} when T =:= 16#01; T =:= 16#02; T =:= 16#03 ->
                    Enc;
                {ok, Enc} ->
                    case eth_rlp:decode(Enc) of
                        {ok, Term, <<>>} -> Term;
                        _ -> []
                    end;
                {error, _} ->
                    []
            end;
        _ ->
            []
    end.

%% Snap request/response round trip returning the decoded reply term
%% (verification is the caller's job). Offsets relative to snap base.
snap_call(S, SendOff, ExpectOff, EncReq) ->
    case S#st.eth of
        #{snap := Snap} ->
            Base = maps:get(base, Snap),
            Decode = fun(Data) ->
                case eth_rlp:decode(Data) of
                    {ok, Term, _} -> {ok, Term};
                    {error, _} = E -> E
                end
            end,
            {Reply, S1} = fetch_request(S#st{fetching = true}, Base + SendOff,
                                        EncReq, Base + ExpectOff,
                                        Decode, fun(_) -> ok end),
            S2 = S1#st{fetching = false},
            erlang:send_after(?POLL_MS, self(), poll),
            {reply, Reply, S2};
        _ ->
            {reply, {error, no_snap}, S}
    end.

%% Outbound request/response round trip: send a request and block in the
%% call while waiting for the matching response code (Ping is answered
%% inline, Disconnect stops). Decode/Verify decode and check the body.
%% Returns {Reply, State} so framing state survives.
fetch_request(S, SendCode, EncReq, ExpectCode, Decode, Verify) ->
    case eth_rlpx:send(S#st.sess, S#st.sock, SendCode, EncReq) of
        {ok, Sess1} ->
            fetch_wait(S#st{sess = Sess1}, ExpectCode, Decode, Verify,
                       erlang:monotonic_time(millisecond) + 15000);
        {error, _} = E ->
            {E, S}
    end.

fetch_wait(S, ExpectCode, Decode, Verify, Deadline) ->
    Timeout = max(1, Deadline - erlang:monotonic_time(millisecond)),
    case eth_rlpx:recv(S#st.sess, S#st.sock, Timeout) of
        {ok, Code, Data, Sess1} when Code =:= ExpectCode ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            case Decode(Data) of
                {ok, Term} ->
                    case Verify(Term) of
                        ok -> {{ok, Term}, S1};
                        {error, _} = E -> {E, S1}
                    end;
                {error, _} = E ->
                    {E, S1}
            end;
        {ok, 2, _, Sess1} ->
            S1 = S#st{sess = Sess1,
                      last_in = erlang:monotonic_time(millisecond)},
            case eth_rlpx:send(Sess1, S#st.sock, 3, eth_rlp:encode([])) of
                {ok, Sess2} -> fetch_wait(S1#st{sess = Sess2}, ExpectCode, Decode, Verify, Deadline);
                {error, _} = E -> {E, S1}
            end;
        {ok, 1, _, Sess1} ->
            {{error, remote_disconnect}, S#st{sess = Sess1}};
        {ok, _, _, Sess1} ->
            fetch_wait(S#st{sess = Sess1}, ExpectCode, Decode, Verify, Deadline);
        {error, timeout} ->
            case Deadline > erlang:monotonic_time(millisecond) of
                true -> fetch_wait(S, ExpectCode, Decode, Verify, Deadline);
                false -> {{error, timeout}, S}
            end;
        {error, _} = E ->
            {E, S}
    end.

to_skip(Skip) ->
    case Skip of
        I when is_integer(I) -> I;
        _ -> 0
    end.

eth_ready(#st{eth = undefined}) -> false;
eth_ready(#st{eth = #{version := V, status := Their} = Eth}) ->
    #{version => V, head => maps:get(best, Their, undefined),
      snap => maps:is_key(snap, Eth)}.
