-module(eth_discv4).
-behaviour(gen_server).

%% Ethereum node discovery v4 (UDP wire + k-bucket table).
%%
%% Increment 1: packet encode/decode with secp256k1 auth, endpoint and
%% neighbour codecs, an ETS k-bucket routing table, and a UDP responder
%% that bonds with bootnodes. Opt-in via DISCV4_ENABLED (default false);
%% RLPx and peer block fetch are later increments, so chain sync still
%% uses the upstream RPC while discovery runs alongside it.
%%
%% Packet layout: Hash || Sig || Type || Data, where
%%   Hash = Keccak256(Sig || Type || Data),
%%   Sig  = Sign(Keccak256(Type || Data)) as R || S || V (65 bytes),
%%   Type = 0x01 ping | 0x02 pong | 0x03 findnode | 0x04 neighbors,
%%   Data = RLP.

-export([start_link/1, status/0, status/1, peers/0, peers/1]).
-export([generate_key/0, node_id/1]).
-export([encode_packet/3, decode_packet/1]).
-export([ping/3, pong/2, findnode/1, neighbors/1]).
-export([encode_endpoint/3, decode_endpoint/1, parse_enode/1]).
-export([table_new/0, table_add/3, table_closest/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(PING, 1).
-define(PONG, 2).
-define(FINDNODE, 3).
-define(NEIGHBORS, 4).
-define(K, 16).
-define(PING_TTL_S, 60).
-define(PING_TIMEOUT_MS, 3000).
-define(TICK_MS, 5000).
-define(MAX_PENDING, 64).

-record(st, {sock,
             port,
             priv,
             id,
             tab,
             pending = #{},
             bootnodes = []}).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

start_link(Cfg) ->
    Name = maps:get(name, Cfg, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Cfg, []).

status() -> status(?MODULE).
status(Name) -> gen_server:call(Name, status).

peers() -> peers(?MODULE).
peers(Name) -> gen_server:call(Name, peers).

generate_key() -> eth_secp256k1:generate_key().
node_id(Priv) -> eth_secp256k1:node_id(Priv).

%% Encode a packet of Type (1..4) with RLP term Data.
encode_packet(Type, Data, Priv)
  when Type >= ?PING, Type =< ?NEIGHBORS, byte_size(Priv) =:= 32 ->
    Payload = eth_rlp:encode(Data),
    SigInput = <<Type, Payload/binary>>,
    Digest = eth_keccak:hash(SigInput),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Sig = <<R:256, S:256, V:8>>,
    Hash = eth_keccak:hash(<<Sig/binary, SigInput/binary>>),
    <<Hash/binary, Sig/binary, SigInput/binary>>.

%% Decode and authenticate a packet. Returns
%% {ok, #{type := Type, data := RLPValue, id := NodeID, hash := Hash}}.
decode_packet(<<Hash:32/binary, R:256, S:256, V:8, Type:8, Payload/binary>>)
  when Type >= ?PING, Type =< ?NEIGHBORS, (V =:= 0 orelse V =:= 1) ->
    case eth_keccak:hash(<<R:256, S:256, V:8, Type:8, Payload/binary>>) of
        Hash ->
            Digest = eth_keccak:hash(<<Type:8, Payload/binary>>),
            case eth_secp256k1:recover(Digest, R, S, V) of
                {ok, ID} ->
                    case eth_rlp:decode(Payload) of
                        {ok, Data, <<>>} ->
                            {ok, #{type => Type, data => Data, id => ID,
                                   hash => Hash}};
                        {ok, _, _} ->
                            {error, trailing_bytes};
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end;
        _ ->
            {error, bad_hash}
    end;
decode_packet(_) ->
    {error, bad_packet}.

%% Endpoint RLP term: [IP, UDPport, TCPport]. IPv4 only for now.
encode_endpoint({A, B, C, D}, UDPPort, TCPPort)
  when is_integer(A), is_integer(UDPPort), is_integer(TCPPort) ->
    [<<A, B, C, D>>, UDPPort, TCPPort].

decode_endpoint([<<A, B, C, D>>, UDP, TCP])
  when is_binary(UDP) orelse is_integer(UDP) ->
    {ok, {{A, B, C, D}, to_int(UDP), to_int(TCP)}};
decode_endpoint(_) ->
    {error, bad_endpoint}.

%% Ping RLP term. Expiration defaults to now + 60s.
ping(FromEP, ToEP, Exp) -> [4, FromEP, ToEP, Exp].

%% Pong RLP term. PingHash is the hash of the ping being answered.
pong(ToEP, PingHash) -> [ToEP, PingHash, expiration()].

%% Findnode RLP term. Target is a 64-byte node id.
findnode(Target) when byte_size(Target) =:= 64 -> [Target, expiration()].

%% Neighbors RLP term. Nodes are #{id, ip, udp, tcp} maps.
neighbors(Nodes) -> [[encode_node(N) || N <- Nodes], expiration()].

expiration() -> erlang:system_time(second) + ?PING_TTL_S.

%% Parse "enode://<128 hex id>@<ip|host>:<port>".
parse_enode("enode://" ++ Rest) ->
    case string:split(Rest, "@", all) of
        [IDHex, Addr] ->
            case string:split(Addr, ":", trailing) of
                [Host, PortS] ->
                    case {hex_id(IDHex), resolve(Host), string:to_integer(PortS)} of
                        {{ok, ID}, {ok, IP}, {Port, ""}} when Port > 0 ->
                            {ok, #{id => ID, ip => IP, udp => Port, tcp => Port}};
                        _ ->
                            {error, bad_enode}
                    end;
                _ ->
                    {error, bad_enode}
            end;
        _ ->
            {error, bad_enode}
    end;
parse_enode(_) ->
    {error, bad_enode}.

%% ---------------------------------------------------------------------------
%% K-bucket routing table (ETS, owned by caller/server)
%% ---------------------------------------------------------------------------

table_new() ->
    ets:new(?MODULE, [set, {keypos, 1}]).

%% Add a node map #{id, ip, udp, tcp}. SelfID is our own node id (never
%% stored). Eviction: when a bucket is full the stalest entry is replaced.
%% Add a node map #{id, ip, udp, tcp}. SelfID is our own node id (never
%% stored). Entries are {ID, Node, Bucket, LastSeen}. Eviction: when a
%% bucket is full the stalest entry is replaced.
table_add(Tab, SelfID, Node) ->
    ID = maps:get(id, Node),
    case ID =:= SelfID of
        true ->
            false;
        false ->
            B = bucket(SelfID, ID),
            Now = erlang:monotonic_time(millisecond),
            Stored = Node#{bonded => maps:get(bonded, Node, false)},
            case ets:lookup(Tab, ID) of
                [{ID, _Old, _B, _T}] ->
                    ets:insert(Tab, {ID, Stored, B, Now}),
                    true;
                [] ->
                    Members = [E || E = {_, _, EB, _} <- ets:tab2list(Tab), EB =:= B],
                    case length(Members) < ?K of
                        true ->
                            ets:insert(Tab, {ID, Stored, B, Now}),
                            true;
                        false ->
                            {_, OldID} = lists:min([{T, KID} || {KID, _, _, T} <- Members]),
                            ets:delete(Tab, OldID),
                            ets:insert(Tab, {ID, Stored, B, Now}),
                            true
                    end
            end
    end.

%% N closest nodes to Target by xor distance.
table_closest(Tab, Target, N) ->
    Nodes = [Node || {_, Node, _, _} <- ets:tab2list(Tab)],
    ByID = maps:from_list([{maps:get(id, Nd), Nd} || Nd <- Nodes]),
    Dist = [{distance(Target, maps:get(id, Nd)), maps:get(id, Nd)} || Nd <- Nodes],
    pick_closest(lists:sort(Dist), ByID, N).

%% ---------------------------------------------------------------------------
%% gen_server (UDP responder)
%% ---------------------------------------------------------------------------

init(Cfg) ->
    Port = maps:get(port, Cfg, 30303),
    Boot = maps:get(bootnodes, Cfg, []),
    Priv = case maps:get(privkey, Cfg, undefined) of
               undefined -> generate_key();
               P -> P
           end,
    ID = node_id(Priv),
    Tab = table_new(),
    Nodes = lists:filtermap(fun parse_bootnode/1, Boot),
    case gen_udp:open(Port, [binary, {active, once}, {reuseaddr, true}]) of
        {ok, Sock} ->
            {ok, Actual} = inet:port(Sock),
            logger:notice("etherlang: discv4 listening on udp ~p id=~s",
                          [Actual, binary:encode_hex(binary:part(ID, 0, 8))]),
            S0 = #st{sock = Sock, port = Actual, priv = Priv, id = ID,
                     tab = Tab, bootnodes = Nodes},
            S1 = lists:foldl(fun ping_node/2, S0, Nodes),
            erlang:send_after(?TICK_MS, self(), tick),
            {ok, S1};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(status, _From, S) ->
    Entries = ets:tab2list(S#st.tab),
    Bonded = length([1 || {_, N, _, _} <- Entries, maps:get(bonded, N, false)]),
    {reply, #{id => S#st.id, port => S#st.port,
              table_size => length(Entries), bonded => Bonded,
              pending => maps:size(S#st.pending)}, S};
handle_call(peers, _From, S) ->
    {reply, [N || {_, N, _, _} <- ets:tab2list(S#st.tab)], S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info({udp, Sock, IP, InPort, Packet}, #st{sock = Sock} = S) ->
    inet:setopts(Sock, [{active, once}]),
    {noreply, handle_packet(Packet, IP, InPort, S)};
handle_info({timeout, _Ref, {ping_timeout, Hash}}, S) ->
    {noreply, S#st{pending = maps:remove(Hash, S#st.pending)}};
handle_info(tick, S) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {noreply, rebond(S)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #st{sock = Sock}) ->
    _ = (try gen_udp:close(Sock) catch _:_ -> ok end),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Packet handling
%% ---------------------------------------------------------------------------

handle_packet(Packet, IP, InPort, S) ->
    case decode_packet(Packet) of
        {ok, #{type := ?PING, data := Data, id := ID, hash := Hash}} ->
            handle_ping(Data, ID, Hash, IP, InPort, S);
        {ok, #{type := ?PONG, data := Data, id := ID}} ->
            handle_pong(Data, ID, IP, InPort, S);
        {ok, #{type := ?FINDNODE, data := Data, id := ID}} ->
            handle_findnode(Data, ID, IP, InPort, S);
        {ok, #{type := ?NEIGHBORS, data := Data, id := ID}} ->
            handle_neighbors(Data, ID, S);
        {error, Reason} ->
            logger:debug("etherlang: discv4 dropping packet (~p)", [Reason]),
            S
    end.

handle_ping([_Vsn, FromEP, _ToEP, Exp], ID, Hash, IP, InPort, S) ->
    case fresh(Exp) of
        false ->
            S;
        true ->
            Sender = sender_node(ID, FromEP, IP, InPort),
            table_add(S#st.tab, S#st.id, Sender),
            ToEP = encode_endpoint(IP, InPort, InPort),
            Pong = encode_packet(?PONG, pong(ToEP, Hash), S#st.priv),
            gen_udp:send(S#st.sock, IP, InPort, Pong),
            S
    end;
handle_ping(_, _, _, _, _, S) ->
    S.

handle_pong([_ToEP, PingHash, _Exp], ID, IP, InPort, S) ->
    H = to_bin(PingHash),
    case maps:take(H, S#st.pending) of
        {{_IP, _Port, TRef}, Pending} ->
            _ = erlang:cancel_timer(TRef),
            table_add(S#st.tab, S#st.id,
                      #{id => ID, ip => IP, udp => InPort, tcp => InPort,
                        bonded => true}),
            S#st{pending = Pending};
        error ->
            S
    end;
handle_pong(_, _, _, _, S) ->
    S.

handle_findnode([Target, _Exp], _ID, IP, InPort, S) ->
    Nodes = table_closest(S#st.tab, to_bin(Target), ?K),
    Reply = encode_packet(?NEIGHBORS, neighbors(Nodes), S#st.priv),
    gen_udp:send(S#st.sock, IP, InPort, Reply),
    S;
handle_findnode(_, _, _, _, S) ->
    S.

handle_neighbors([Nodes, _Exp], _ID, S) when is_list(Nodes) ->
    lists:foldl(fun(Raw, Acc) -> learn_node(Raw, Acc) end, S, Nodes);
handle_neighbors(_, _, S) ->
    S.

learn_node([IPBin, UDP, TCP, ID], S) ->
    case {decode_ip(IPBin), to_bin(ID)} of
        {{ok, IP}, NID} when byte_size(NID) =:= 64 ->
            Node = #{id => NID, ip => IP, udp => to_int(UDP), tcp => to_int(TCP),
                     bonded => false},
            case table_add(S#st.tab, S#st.id, Node) of
                true -> maybe_ping(Node, S);
                false -> S
            end;
        _ ->
            S
    end;
learn_node(_, S) ->
    S.

%% Periodic maintenance: re-ping bootnodes while the table is small and
%% probe unbonded entries.
rebond(S) ->
    case ets:info(S#st.tab, size) < ?K of
        true ->
            lists:foldl(fun ping_node/2, S, S#st.bootnodes);
        false ->
            S
    end.

%% Send a ping and track it so the pong bonds the peer. Shared by bootnode
%% dialling, neighbour learning, and periodic maintenance.
ping_node(#{ip := IP, udp := Port} = _Node, S) ->
    case maps:size(S#st.pending) < ?MAX_PENDING of
        false ->
            S;
        true ->
            FromEP = encode_endpoint(loopback_ip(), S#st.port, S#st.port),
            ToEP = encode_endpoint(IP, Port, Port),
            Pkt = encode_packet(?PING, ping(FromEP, ToEP, expiration()), S#st.priv),
            Hash = binary:part(Pkt, 0, 32),
            gen_udp:send(S#st.sock, IP, Port, Pkt),
            TRef = erlang:start_timer(?PING_TIMEOUT_MS, self(), {ping_timeout, Hash}),
            S#st{pending = (S#st.pending)#{Hash => {IP, Port, TRef}}}
    end.

maybe_ping(Node, S) ->
    ping_node(Node, S).

sender_node(ID, FromEP, IP, InPort) ->
    case FromEP of
        [_, _, _] ->
            case decode_endpoint(FromEP) of
                {ok, {EIP, _UDP, TCP}} ->
                    #{id => ID, ip => EIP, udp => InPort, tcp => TCP, bonded => false};
                {error, _} ->
                    #{id => ID, ip => IP, udp => InPort, tcp => InPort, bonded => false}
            end;
        _ ->
            #{id => ID, ip => IP, udp => InPort, tcp => InPort, bonded => false}
    end.

loopback_ip() -> {127, 0, 0, 1}.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

fresh(Exp) ->
    Now = erlang:system_time(second),
    to_int(Exp) + 60 > Now.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B) -> binary:decode_unsigned(B);
to_int(_) -> 0.

to_bin(B) when is_binary(B) -> B;
to_bin(I) when is_integer(I) -> binary:encode_unsigned(I);
to_bin(_) -> <<>>.

bucket(SelfID, ID) ->
    D = distance(SelfID, ID),
    case D of
        0 -> 0;
        _ -> bit_length(D)
    end.

bit_length(0) -> 0;
bit_length(N) -> bit_length(N bsr 1, 1).
bit_length(0, Acc) -> Acc;
bit_length(N, Acc) -> bit_length(N bsr 1, Acc + 1).

distance(A, B) ->
    binary:decode_unsigned(crypto:exor(A, B)).

pick_closest(Sorted, ByID, N) ->
    pick_closest(Sorted, ByID, N, [], 0).

pick_closest(_, _, N, Acc, Got) when Got >= N -> lists:reverse(Acc);
pick_closest([], _, _, Acc, _) -> lists:reverse(Acc);
pick_closest([{_, ID} | Rest], ByID, N, Acc, Got) ->
    pick_closest(Rest, ByID, N, [maps:get(ID, ByID) | Acc], Got + 1).

encode_node(#{id := ID, ip := IP, udp := UDP, tcp := TCP}) ->
    [encode_ip(IP), UDP, TCP, ID].

encode_ip({A, B, C, D}) -> <<A, B, C, D>>.

decode_ip(<<A, B, C, D>>) -> {ok, {A, B, C, D}};
decode_ip(_) -> error.

hex_id(Hex) ->
    try {ok, binary:decode_hex(list_to_binary(Hex))}
    catch _:_ -> error
    end.

parse_bootnode(E) ->
    case parse_enode(E) of
        {ok, N} -> {true, N};
        {error, _} -> false
    end.

resolve(Host) ->
    case inet:parse_address(Host) of
        {ok, IP} -> {ok, IP};
        {error, _} ->
            case inet:getaddr(Host, inet) of
                {ok, IP} -> {ok, IP};
                {error, _} -> error
            end
    end.
