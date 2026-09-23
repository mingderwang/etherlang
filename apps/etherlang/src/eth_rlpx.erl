-module(eth_rlpx).

%% RLPx transport (EIP-8 handshake, AES-CTR framing, keccak MACs, p2p Hello).
%%
%% Follows go-ethereum's p2p/rlpx layout: ECIES-encrypted auth/ack bodies,
%% secrets derived from ephemeral ECDH + nonces, then framed capability
%% messages. Snappy is enabled right after the Hello exchange on both ends.
%% Session state is an opaque map threaded through send/recv (single owner
%% per connection, e.g. eth_peer_conn).

-export([dial/4, dial/5, accept/3, initiator/4, recipient/3]).
-export([hello/3, send/4, recv/3, disconnect/3, ping/2]).
-export([remote_id/1]).

-define(VSN, 4).
-define(P2P_VERSION, 5).
-define(HANDSHAKE_TIMEOUT, 10000).
-define(MAX_FRAME, 16#FFFFFF).
-define(ECIES_OVERHEAD, 113).
-define(AUTH_PAD, 128).

-record(sess, {enc,
               dec,
               egress,
               ingress,
               mackey,
               snappy = false,
               remote}).

%% ---------------------------------------------------------------------------
%% Handshake
%% ---------------------------------------------------------------------------

%% Connect and run the initiator handshake. RemoteID is the 64-byte node id
%% we intend to dial (used for ECIES and the static shared secret).
dial(Host, Port, LocalPriv, RemoteID) ->
    dial(Host, Port, LocalPriv, RemoteID, ?HANDSHAKE_TIMEOUT).

dial(Host, Port, LocalPriv, RemoteID, Timeout)
  when byte_size(LocalPriv) =:= 32, byte_size(RemoteID) =:= 64 ->
    case gen_tcp:connect(Host, Port,
                         [binary, {packet, raw}, {active, false},
                          {nodelay, true}, {send_timeout, Timeout}],
                         Timeout) of
        {ok, Sock} ->
            case initiator(Sock, LocalPriv, RemoteID, Timeout) of
                {ok, Sess} -> {ok, Sess, Sock};
                {error, _} = E ->
                    (try gen_tcp:close(Sock) catch _:_ -> ok end),
                    E
            end;
        {error, _} = E ->
            E
    end.

%% Run the recipient handshake on an accepted socket.
accept(Sock, LocalPriv, Timeout) when byte_size(LocalPriv) =:= 32 ->
    case recipient(Sock, LocalPriv, Timeout) of
        {ok, Sess} -> {ok, Sess, Sock};
        {error, _} = E ->
            (try gen_tcp:close(Sock) catch _:_ -> ok end),
            E
    end.

remote_id(#sess{remote = R}) -> R.

initiator(Sock, LocalPriv, RemoteID, Timeout) ->
    InitNonce = crypto:strong_rand_bytes(32),
    {EphPub65, EphPriv} = crypto:generate_key(ecdh, secp256k1),
    <<16#04, _EphPub:64/binary>> = EphPub65,
    Token = eth_ecies:ecdh(LocalPriv, <<16#04, RemoteID/binary>>),
    Signed = crypto:exor(Token, InitNonce),
    {R, S, V} = eth_secp256k1:sign(Signed, EphPriv),
    Sig = <<R:256, S:256, V:8>>,
    LocalPub = eth_ecies:pubkey(LocalPriv),
    Body = eth_rlp:encode([Sig, LocalPub, InitNonce, ?VSN]),
    Auth = seal(Body, RemoteID),
    case gen_tcp:send(Sock, Auth) of
        ok ->
            case read_handshake(Sock, LocalPriv, Timeout) of
                {ok, AckPacket, [RemoteEphPub, RespNonce | _]} ->
                    finish_initiator(Sock, LocalPriv, RemoteID, EphPriv,
                                     InitNonce, RemoteEphPub, RespNonce,
                                     Auth, AckPacket);
                {ok, _, _} ->
                    {error, bad_ack};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

recipient(Sock, LocalPriv, Timeout) ->
    case read_handshake(Sock, LocalPriv, Timeout) of
        {ok, AuthPacket, [SigBin, InitPub, InitNonce | _]} ->
            handle_auth(Sock, LocalPriv, AuthPacket, SigBin, InitPub,
                        InitNonce, Timeout);
        {ok, _, _} ->
            {error, bad_auth};
        {error, _} = E ->
            E
    end.

handle_auth(Sock, LocalPriv, AuthPacket, SigBin, InitPubBin, InitNonceBin, _Timeout) ->
    {EphPub65, EphPriv} = crypto:generate_key(ecdh, secp256k1),
    <<16#04, EphPub:64/binary>> = EphPub65,
    RespNonce = crypto:strong_rand_bytes(32),
    InitPub = to_bin(InitPubBin),
    InitNonce = to_bin(InitNonceBin),
    case byte_size(InitPub) =:= 64 andalso byte_size(InitNonce) =:= 32 of
        false ->
            {error, bad_auth};
        true ->
            Token = eth_ecies:ecdh(LocalPriv, <<16#04, InitPub/binary>>),
            Signed = crypto:exor(Token, InitNonce),
            case recover_sig(SigBin, Signed) of
                {ok, RemoteEphPub} ->
                    AckBody = eth_rlp:encode([EphPub, RespNonce, ?VSN]),
                    Ack = seal(AckBody, InitPub),
                    case gen_tcp:send(Sock, Ack) of
                        ok ->
                            finish_recipient(LocalPriv, InitPub, EphPriv,
                                             InitNonce, RemoteEphPub, RespNonce,
                                             AuthPacket, Ack);
                        {error, _} = E ->
                            E
                    end;
                {error, _} = E ->
                    E
            end
    end.

finish_initiator(_Sock, _LocalPriv, RemoteID, EphPriv, InitNonce,
                 RemoteEphPubBin, RespNonceBin, Auth, Ack) ->
    RemoteEphPub = to_bin(RemoteEphPubBin),
    RespNonce = to_bin(RespNonceBin),
    case byte_size(RemoteEphPub) =:= 64 andalso byte_size(RespNonce) =:= 32 of
        false ->
            {error, bad_ack};
        true ->
            {ok, init_session(EphPriv, RemoteEphPub, InitNonce, RespNonce,
                              Auth, Ack, true, RemoteID)}
    end.

finish_recipient(_LocalPriv, InitPub, EphPriv, InitNonce, RemoteEphPub,
                 RespNonce, Auth, Ack) ->
    {ok, init_session(EphPriv, RemoteEphPub, InitNonce, RespNonce,
                       Auth, Ack, false, InitPub)}.

init_session(EphPriv, RemoteEphPub, InitNonce, RespNonce, Auth, Ack,
             Initiator, RemoteID) ->
    Ecdhe = eth_ecies:ecdh(EphPriv, <<16#04, RemoteEphPub/binary>>),
    Shared = eth_keccak:hash(<<Ecdhe/binary,
                               (eth_keccak:hash(<<RespNonce/binary,
                                                  InitNonce/binary>>))/binary>>),
    AES = eth_keccak:hash(<<Ecdhe/binary, Shared/binary>>),
    MAC = eth_keccak:hash(<<Ecdhe/binary, AES/binary>>),
    Mac1 = mac_init(MAC, RespNonce, Auth),
    Mac2 = mac_init(MAC, InitNonce, Ack),
    {Egress, Ingress} = case Initiator of
                            true -> {Mac1, Mac2};
                            false -> {Mac2, Mac1}
                        end,
    ZeroIV = <<0:128>>,
    #sess{enc = crypto:crypto_init(aes_256_ctr, AES, ZeroIV, true),
          dec = crypto:crypto_init(aes_256_ctr, AES, ZeroIV, false),
          egress = Egress,
          ingress = Ingress,
          mackey = MAC,
          remote = RemoteID}.

mac_init(MAC, Nonce, Packet) ->
    K0 = eth_keccak:init(),
    K1 = eth_keccak:update(K0, crypto:exor(MAC, Nonce)),
    eth_keccak:update(K1, Packet).

recover_sig(<<R:256, S:256, V:8>>, Digest)
  when (V =:= 0 orelse V =:= 1), byte_size(Digest) =:= 32 ->
    case eth_secp256k1:recover(Digest, R, S, V) of
        {ok, Pub} -> {ok, Pub};
        {error, _} = E -> E
    end;
recover_sig(_, _) ->
    {error, bad_sig}.

%% ECIES-seal an RLP handshake body for a 64-byte recipient id.
seal(Body, RemoteID) ->
    Padded = <<Body/binary, 0:(?AUTH_PAD * 8)>>,
    Prefix = <<(byte_size(Padded) + ?ECIES_OVERHEAD):16/big>>,
    Enc = eth_ecies:encrypt(RemoteID, Padded, Prefix),
    <<Prefix/binary, Enc/binary>>.

read_handshake(Sock, LocalPriv, Timeout) ->
    case gen_tcp:recv(Sock, 2, Timeout) of
        {ok, Prefix} ->
            <<Size:16/big>> = Prefix,
            case Size =< 2048 of
                false ->
                    {error, handshake_too_big};
                true ->
                    case gen_tcp:recv(Sock, Size, Timeout) of
                        {ok, Enc} ->
                            Packet = <<Prefix/binary, Enc/binary>>,
                            case eth_ecies:decrypt(LocalPriv, Enc, Prefix) of
                                {ok, Plain} ->
                                    case eth_rlp:decode(Plain) of
                                        {ok, Items, _} when is_list(Items) ->
                                            {ok, Packet, Items};
                                        _ ->
                                            {error, bad_handshake_rlp}
                                    end;
                                {error, _} = E ->
                                    E
                            end;
                        {error, _} = E ->
                            E
                    end
            end;
        {error, _} = E ->
            E
    end.

%% ---------------------------------------------------------------------------
%% Capability messages (p2p Hello + Ping/Pong/Disconnect)
%% ---------------------------------------------------------------------------

%% Exchange Hellos: send ours (uncompressed), read theirs, then enable
%% snappy on both directions. Returns {ok, Sess, RemoteHello}.
hello(Sess, Sock, Opts) ->
    NodeID = maps:get(node_id, Opts),
    ClientID = maps:get(client_id, Opts, <<"etherlang/0.1.0">>),
    Caps = maps:get(caps, Opts, []),
    Port = maps:get(listen_port, Opts, 0),
    OurHello = [?P2P_VERSION, ClientID,
                [[Name, Ver] || {Name, Ver} <- Caps], Port, NodeID],
    case send_frame(Sess, Sock, 0, eth_rlp:encode(OurHello)) of
        {ok, Sess1} ->
            case recv_frame(Sess1, Sock, ?HANDSHAKE_TIMEOUT) of
                {ok, 0, Data, Sess2} ->
                    case eth_rlp:decode(Data) of
                        {ok, Items, _} when is_list(Items) ->
                            {ok, Sess2#sess{snappy = true}, parse_hello(Items)};
                        _ ->
                            {error, bad_hello}
                    end;
                {ok, _, _, _} ->
                    {error, expected_hello};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

parse_hello([Vsn, ClientID, Caps, Port, NodeID | _]) ->
    #{version => to_int(Vsn), client_id => to_bin(ClientID),
      caps => [{to_bin(N), to_int(V)} || [N, V] <- Caps],
      listen_port => to_int(Port), node_id => to_bin(NodeID)};
parse_hello(_) ->
    {error, bad_hello}.

%% Send a capability message. Data is the RLP-encoded message body.
send(Sess, Sock, Code, Data) ->
    send_frame(Sess, Sock, Code, Data).

%% Receive a capability message. Returns {ok, Code, Data, Sess}.
recv(Sess, Sock, Timeout) ->
    case recv_frame(Sess, Sock, Timeout) of
        {ok, Code, Wire, Sess1} ->
            Data = case Sess1#sess.snappy of
                       true ->
                           case eth_snappy:decompress(Wire) of
                               {ok, Plain} -> Plain;
                               {error, _} -> error
                           end;
                       false ->
                           Wire
                   end,
            case Data of
                error -> {error, bad_snappy};
                _ -> {ok, Code, Data, Sess1}
            end;
        {error, _} = E ->
            E
    end.

%% p2p Ping (0x02): send and wait for Pong (0x03).
ping(Sess, Sock) ->
    case send(Sess, Sock, 2, eth_rlp:encode([])) of
        {ok, Sess1} ->
            case recv(Sess1, Sock, ?HANDSHAKE_TIMEOUT) of
                {ok, 3, _, Sess2} -> {ok, Sess2};
                {ok, _, _, _} -> {error, expected_pong};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

%% p2p Disconnect (0x01) with a reason code.
disconnect(Sess, Sock, Reason) ->
    _ = send(Sess, Sock, 1, eth_rlp:encode([Reason])),
    (try gen_tcp:close(Sock) catch _:_ -> ok end),
    ok.

%% ---------------------------------------------------------------------------
%% Framing
%% ---------------------------------------------------------------------------

send_frame(Sess, Sock, Code, Data) when byte_size(Data) =< ?MAX_FRAME ->
    Payload = case Sess#sess.snappy of
                  true -> eth_snappy:compress(Data);
                  false -> Data
              end,
    CodeBin = eth_rlp:encode(Code),
    FSize = byte_size(CodeBin) + byte_size(Payload),
    case FSize =< ?MAX_FRAME of
        false ->
            {error, message_too_large};
        true ->
            Header = <<FSize:24/big, 16#C2, 16#80, 16#80, 0:80>>,
            {HeaderCt, Enc1} = ctr(Sess#sess.enc, Header),
            {HeaderMAC, Egress1} = mac_header(Sess, HeaderCt),
            PadLen = (16 - (FSize rem 16)) rem 16,
            FrameData = <<CodeBin/binary, Payload/binary, 0:(PadLen * 8)>>,
            {FrameCt, Enc2} = ctr(Enc1, FrameData),
            {FrameMAC, Egress2} = mac_frame(Sess#sess{mackey = Sess#sess.mackey,
                                                      egress = Egress1}, FrameCt),
            case gen_tcp:send(Sock, <<HeaderCt/binary, HeaderMAC/binary,
                                      FrameCt/binary, FrameMAC/binary>>) of
                ok ->
                    {ok, Sess#sess{enc = Enc2, egress = Egress2}};
                {error, _} = E ->
                    E
            end
    end;
send_frame(_, _, _, _) ->
    {error, message_too_large}.

recv_frame(Sess, Sock, Timeout) ->
    case gen_tcp:recv(Sock, 32, Timeout) of
        {ok, <<HeaderCt:16/binary, HeaderMAC:16/binary>>} ->
            recv_frame_header(Sess, Sock, Timeout, HeaderCt, HeaderMAC);
        {ok, _} ->
            {error, short_header};
        {error, _} = E ->
            E
    end.

recv_frame_header(Sess, Sock, Timeout, HeaderCt, HeaderMAC) ->
    {WantMAC, Ingress1} = mac_header(Sess#sess{egress = Sess#sess.ingress}, HeaderCt),
    case hash_equals(WantMAC, HeaderMAC) of
        false ->
            {error, bad_header_mac};
        true ->
            {Header, Dec1} = ctr(Sess#sess.dec, HeaderCt),
            <<FSize:24/big, _/binary>> = Header,
            case FSize =< ?MAX_FRAME of
                false ->
                    {error, frame_too_large};
                true ->
                    RSize = FSize + ((16 - (FSize rem 16)) rem 16),
                    recv_frame_body(Sess, Sock, Timeout, RSize, FSize,
                                    Sess#sess{ingress = Ingress1, dec = Dec1})
            end
    end.

recv_frame_body(_Sess, Sock, Timeout, RSize, FSize, Sess1) ->
    case gen_tcp:recv(Sock, RSize + 16, Timeout) of
        {ok, Blob} ->
            <<FrameCt:RSize/binary, FrameMAC:16/binary>> = Blob,
            {WantMAC, Ingress2} = mac_frame(Sess1#sess{egress = Sess1#sess.ingress}, FrameCt),
            case hash_equals(WantMAC, FrameMAC) of
                false ->
                    {error, bad_frame_mac};
                true ->
                    {Frame, Dec2} = ctr(Sess1#sess.dec, FrameCt),
                    <<Wanted:FSize/binary, _/binary>> = Frame,
                    case eth_rlp:decode(Wanted) of
                        {ok, CodeBin, Rest} ->
                            {ok, to_int(CodeBin), Rest,
                             Sess1#sess{ingress = Ingress2, dec = Dec2}};
                        {error, _} ->
                            {error, bad_rlp}
                    end
            end;
        {error, _} = E ->
            E
    end.

%% ---------------------------------------------------------------------------
%% Crypto helpers
%% ---------------------------------------------------------------------------

%% AES-CTR keystream: the crypto state reference is advanced in place and
%% returned alongside the ciphertext for explicit threading.
ctr(State, Data) ->
    {crypto:crypto_update(State, Data), State}.
mac_header(#sess{mackey = Key, egress = K}, Seed) ->
    Sum1 = eth_keccak:digest(K),
    Enc = crypto:crypto_one_time(aes_256_ecb, Key, binary:part(Sum1, 0, 16), true),
    Xored = crypto:exor(Enc, Seed),
    K1 = eth_keccak:update(K, Xored),
    {binary:part(eth_keccak:digest(K1), 0, 16), K1}.

mac_frame(#sess{mackey = Key, egress = K}, FrameCt) ->
    K1 = eth_keccak:update(K, FrameCt),
    Seed = eth_keccak:digest(K1),
    mac_header(#sess{mackey = Key, egress = K1}, binary:part(Seed, 0, 16)).

hash_equals(A, B) ->
    try crypto:hash_equals(A, B)
    catch _:_ -> A =:= B
    end.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B), byte_size(B) =:= 0 -> 0;
to_int(B) when is_binary(B) -> binary:decode_unsigned(B);
to_int(_) -> 0.

to_bin(B) when is_binary(B) -> B;
to_bin(I) when is_integer(I) -> binary:encode_unsigned(I);
to_bin(_) -> <<>>.
