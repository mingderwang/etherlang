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

%% ---------------------------------------------------------------------------
%% D-14: a malformed packet costs the packet, not the process
%% ---------------------------------------------------------------------------
%%
%% `handle_findnode/5' hands the decoded target to `table_closest/3', which
%% measures every table entry against it with `distance/2' = `crypto:exor/2'.
%% That needs two binaries of equal length, and **the target never has to be
%% 64 bytes for the raise to happen**. Two distinct shapes, both measured:
%%
%%   * the target decodes to a **list**. `eth_discv4:to_bin/1' has clauses for a
%%     binary and an integer and nothing else, so a list falls through to
%%     `<<>>' -- and note that `eth_rlpx:to_bin/1' *does* have a `list_to_binary'
%%     clause, so the two copies of this helper in the same tree disagree about
%%     what a list is. That is the sixth hex-decoder copy in this repository.
%%   * the target decodes to a **binary of the wrong length** -- two bytes is
%%     enough, and it reaches `crypto:exor/2' unchanged.
%%
%% Either way it raised from `handle_info' with no `try' around the per-type
%% handler. The child is `restart => permanent' and the supervisor is
%% `intensity => 5, period => 10', so about six packets in ten seconds from any
%% unauthenticated UDP sender ended the whole application.
%%
%% **The control is the point.** The 64-byte target must still be answered, or
%% "nothing was raised" would be satisfied just as well by a handler that did
%% nothing at all -- which is how an assertion like this passes for the wrong
%% reason. So the working case runs first, on the same state, which also
%% establishes the crash's only precondition: a non-empty table.
malformed_findnode_target_is_dropped_and_the_process_survives_test() ->
    {Sock, Priv, ID, Tab} = d14_fixture(),
    S = d14_state(Sock, Priv, ID, Tab),

    {noreply, S1} = d14_send(Sock, ID, Priv, S),
    ?assertEqual(1, length(ets:tab2list(Tab))),

    %% A list target: `to_bin/1' answers <<>>.
    {noreply, S2} = d14_send(Sock, [<<16#01, 16#02>>, 16#03], Priv, S1),

    %% A two-byte binary target: it reaches `crypto:exor/2' unchanged.
    {noreply, _S3} = d14_send(Sock, <<16#01, 16#02>>, Priv, S2),

    %% And the server is still functional, which is stronger than "still alive".
    {noreply, _} = d14_send(Sock, ID, Priv, S2),
    ok.

%% The table must be non-empty, or the crash cannot happen and the malformed
%% cases above would pass without exercising anything.
d14_fixture() ->
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}, {reuseaddr, true}]),
    Priv = eth_discv4:generate_key(),
    ID = eth_discv4:node_id(Priv),
    PeerID = eth_discv4:node_id(eth_discv4:generate_key()),
    Tab = eth_discv4:table_new(),
    true = eth_discv4:table_add(Tab, ID,
                                #{id => PeerID, ip => {127, 0, 0, 1},
                                  udp => 30303, tcp => 30303}),
    {Sock, Priv, ID, Tab}.

%% `#st{ sock, port, priv, id, tab, pending, bootnodes }' is private to
%% eth_discv4, so the record is built by hand. If it gains a field this fails
%% loudly with a badmatch rather than quietly testing something else.
d14_state(Sock, Priv, ID, Tab) ->
    {st, Sock, 30303, Priv, ID, Tab, #{}, []}.

%% Delivered through the real dispatch point -- `handle_info/2' -- rather than by
%% calling the handler, because the missing boundary was at this level and a test
%% one level down would not see it.
d14_send(Sock, Target, Priv, State) ->
    Pkt = eth_discv4:encode_packet(?FINDNODE, [Target, 16#03], Priv),
    eth_discv4:handle_info({udp, Sock, {127, 0, 0, 1}, 30304, Pkt}, State).
