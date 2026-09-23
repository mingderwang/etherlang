-module(eth_discv4_tests).

-include_lib("eunit/include/eunit.hrl").

%% Packet type codes from the discv4 spec.
-define(PING, 1).
-define(PONG, 2).
-define(FINDNODE, 3).
-define(NEIGHBORS, 4).

ping_wire_test() ->
    Priv = eth_discv4:generate_key(),
    ID = eth_discv4:node_id(Priv),
    FromEP = eth_discv4:encode_endpoint({127, 0, 0, 1}, 30303, 30303),
    ToEP = eth_discv4:encode_endpoint({10, 0, 0, 2}, 30304, 30304),
    Exp = erlang:system_time(second) + 60,
    Pkt = eth_discv4:encode_packet(?PING, eth_discv4:ping(FromEP, ToEP, Exp), Priv),
    {ok, #{type := ?PING, data := Data, id := ID, hash := _}} =
        eth_discv4:decode_packet(Pkt),
    [Vsn, FromBack, ToBack, ExpBack] = Data,
    ?assertEqual(<<4>>, Vsn),
    ?assertEqual({ok, {{127, 0, 0, 1}, 30303, 30303}},
                 eth_discv4:decode_endpoint(FromBack)),
    ?assertEqual({ok, {{10, 0, 0, 2}, 30304, 30304}},
                 eth_discv4:decode_endpoint(ToBack)),
    ?assertEqual(Exp, binary:decode_unsigned(ExpBack)).

pong_findnode_neighbors_wire_test() ->
    Priv = eth_discv4:generate_key(),
    ID = eth_discv4:node_id(Priv),
    EP = eth_discv4:encode_endpoint({127, 0, 0, 1}, 30303, 30303),
    PingHash = crypto:strong_rand_bytes(32),
    {ok, #{type := ?PONG, id := ID}} =
        eth_discv4:decode_packet(
          eth_discv4:encode_packet(?PONG, eth_discv4:pong(EP, PingHash), Priv)),
    Target = crypto:strong_rand_bytes(64),
    {ok, #{type := ?FINDNODE, id := ID}} =
        eth_discv4:decode_packet(
          eth_discv4:encode_packet(?FINDNODE, eth_discv4:findnode(Target), Priv)),
    Node = #{id => crypto:strong_rand_bytes(64), ip => {127, 0, 0, 1},
             udp => 30304, tcp => 30304},
    {ok, #{type := ?NEIGHBORS, id := ID}} =
        eth_discv4:decode_packet(
          eth_discv4:encode_packet(?NEIGHBORS, eth_discv4:neighbors([Node]), Priv)).

tamper_test() ->
    Priv = eth_discv4:generate_key(),
    FromEP = eth_discv4:encode_endpoint({127, 0, 0, 1}, 30303, 30303),
    ToEP = eth_discv4:encode_endpoint({10, 0, 0, 2}, 30304, 30304),
    Pkt = eth_discv4:encode_packet(?PING,
                                   eth_discv4:ping(FromEP, ToEP,
                                                  erlang:system_time(second) + 60),
                                   Priv),
    %% Flip a bit in the tail (packet data): hash check must fail.
    Last = binary:at(Pkt, byte_size(Pkt) - 1) bxor 16#01,
    Bad = <<(binary:part(Pkt, 0, byte_size(Pkt) - 1))/binary, Last>>,
    ?assertEqual({error, bad_hash}, eth_discv4:decode_packet(Bad)),
    ?assertEqual({error, bad_packet}, eth_discv4:decode_packet(<<1, 2, 3>>)).

enode_test() ->
    IDHex = binary:encode_hex(crypto:strong_rand_bytes(64)),
    URL = "enode://" ++ binary_to_list(IDHex) ++ "@127.0.0.1:30303",
    {ok, #{ip := {127, 0, 0, 1}, udp := 30303}} = eth_discv4:parse_enode(URL),
    ?assertEqual({error, bad_enode}, eth_discv4:parse_enode("http://x")),
    ?assertEqual({error, bad_enode}, eth_discv4:parse_enode("enode://zz@1.2.3.4:5")).

table_test() ->
    Self = crypto:strong_rand_bytes(64),
    Tab = eth_discv4:table_new(),
    %% Self is never stored.
    ?assertEqual(false,
                 eth_discv4:table_add(Tab, Self,
                                      #{id => Self, ip => {127, 0, 0, 1},
                                        udp => 1, tcp => 1})),
    N1 = #{id => crypto:strong_rand_bytes(64), ip => {127, 0, 0, 1},
           udp => 2, tcp => 2},
    ?assertEqual(true, eth_discv4:table_add(Tab, Self, N1)),
    Closest = eth_discv4:table_closest(Tab, maps:get(id, N1), 16),
    ?assertEqual([N1], [maps:without([bonded], N) || N <- Closest]).

table_eviction_test() ->
    %% Self top bit 0, all others top bit 1: every node lands in bucket 255.
    Self = <<0:1, 0:511>>,
    Tab = eth_discv4:table_new(),
    lists:foreach(fun(I) ->
        ID = <<1:1, I:511>>,
        ?assertEqual(true,
                     eth_discv4:table_add(Tab, Self,
                                          #{id => ID, ip => {127, 0, 0, 1},
                                            udp => 1000 + I, tcp => 1000 + I}))
    end, lists:seq(0, 16)),
    %% Bucket holds K=16; the stalest entry was evicted, size stays 16.
    ?assertEqual(16, ets:info(Tab, size)).

%% Two loopback servers bond over real UDP: A seeds from B's enode.
udp_bond_test() ->
    {ok, _B} = gen_server:start({local, discv4_b}, eth_discv4,
                                #{port => 0, bootnodes => []}, []),
    #{port := PortB} = eth_discv4:status(discv4_b),
    PrivA = eth_discv4:generate_key(),
    IDB = maps:get(id, eth_discv4:status(discv4_b)),
    EnodeB = lists:flatten(io_lib:format("enode://~s@127.0.0.1:~p",
                                         [binary_to_list(binary:encode_hex(IDB)),
                                          PortB])),
    {ok, _A} = gen_server:start({local, discv4_a}, eth_discv4,
                                #{port => 0, privkey => PrivA,
                                  bootnodes => [EnodeB]}, []),
    try
        ok = wait_bonded(),
        #{bonded := BondedA} = eth_discv4:status(discv4_a),
        ?assert(BondedA >= 1)
    after
        gen_server:stop(discv4_a),
        gen_server:stop(discv4_b)
    end.

wait_bonded() -> wait_bonded(50).
wait_bonded(0) -> error(bond_timeout);
wait_bonded(N) ->
    #{table_size := Size} = eth_discv4:status(discv4_b),
    case Size >= 1 of
        true -> ok;
        false -> timer:sleep(100), wait_bonded(N - 1)
    end.
