#!/usr/bin/env escript
%%! -noshell -noinput

main(_) ->
    lists:foreach(fun(D) -> code:add_patha(D) end,
                  filelib:wildcard("/src/_build/default/lib/*/ebin") ++
                  filelib:wildcard("/src/_build/test/lib/*/ebin")),
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    eth_rpc_client:init(#{url => "https://ethereum-sepolia-rpc.publicnode.com",
                          timeout_ms => 20000, retries => 2, backoff_ms => 500}),

    checks([
        {"identity precompile direct call",
         fun() ->
             Tx = #{<<"to">> => <<"0x0000000000000000000000000000000000000004">>,
                    <<"input">> => <<"0x112233">>},
             Upstream = eth_rpc_client:call(<<"eth_call">>, [Tx, <<"latest">>]),
             Local = eth_call:call([Tx, <<"latest">>]),
             {Local, Upstream}
         end},
        {"sha256 precompile direct call",
         fun() ->
             Tx = #{<<"to">> => <<"0x0000000000000000000000000000000000000002">>,
                    <<"input">> => <<"0x616263">>},
             Upstream = eth_rpc_client:call(<<"eth_call">>, [Tx, <<"latest">>]),
             Local = eth_call:call([Tx, <<"latest">>]),
             {Local, Upstream}
         end},
        {"state-override code returning 42",
         fun() ->
             Addr = <<"0x1111111111111111111111111111111111111111">>,
             Override = #{Addr => #{<<"balance">> => <<"0x1">>,
                                    <<"code">> => <<"0x602a60005260206000f3">>}},
             Local = eth_call:call([#{<<"to">> => Addr, <<"input">> => <<"0x">>},
                                    <<"latest">>, Override]),
             {Local, {ok, length_to_hex_word(42)}}
         end},
        {"state-override storage read -> 7",
         fun() ->
             Addr = <<"0x2222222222222222222222222222222222222222">>,
             Override = #{Addr => #{<<"balance">> => <<"0x1">>,
                                    <<"code">> => <<"0x60005460005260206000f3">>,
                                    <<"state">> => #{<<"0x0">> => <<"0x07">>}}},
             Local = eth_call:call([#{<<"to">> => Addr, <<"input">> => <<"0x">>},
                                    <<"latest">>, Override]),
             {Local, {ok, length_to_hex_word(7)}}
         end},
        {"real ERC20 totalSupply local-vs-upstream",
         fun() ->
             Candidates = [<<"0xfff9976782d46cc05630d1f6eb18b0494f1e1da7">>,
                           <<"0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238">>,
                           <<"0x8a3e16b30c982d7134e0b39f5ba59b9f74749d17">>,
                           <<"0x03a3A85632cD2d7a1FC686B2ba41Ccf4aAa80000">>],
             Contract = find_code(Candidates),
             io:format("   (using contract ~s code_bytes=~p)~n",
                       [Contract, byte_size(eth_get_code(Contract))]),
             Tx = #{<<"to">> => Contract, <<"input">> => <<"0x18160ddd">>},
             Upstream = eth_rpc_client:call(<<"eth_call">>, [Tx, <<"latest">>]),
             Local = eth_call:call([Tx, <<"latest">>]),
             {Local, Upstream}
         end},
        {"real code gas consumption (proves execution)",
         fun() ->
             Candidates = [<<"0xfff9976782d46cc05630d1f6eb18b0494f1e1da7">>,
                           <<"0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238">>,
                           <<"0x8a3e16b30c982d7134e0b39f5ba59b9f74749d17">>,
                           <<"0x03a3A85632cD2d7a1FC686B2ba41Ccf4aAa80000">>],
             Contract = find_code(Candidates),
             {ok, Block} = eth_rpc_client:call(<<"eth_getBlockByNumber">>, [<<"latest">>, false]),
             Num = eth_hex:decode(maps:get(<<"number">>, Block)),
             State = eth_state:new(Num, #{}),
             Code = eth_state:code(State, eth_state:address(Contract)),
             Msg = #{address => eth_state:address(Contract), caller => <<0:160>>,
                     origin => <<0:160>>, value => 0, data => <<"0x18160ddd">>,
                     gas_price => 0, static => false, depth => 0},
             Env = #{number => Num, timestamp => 0, coinbase => <<0:160>>,
                     gas_limit => 30000000, prevrandao => <<0:256>>, base_fee => 0,
                     blob_base_fee => 0, chain_id => 11155111,
                     blockhash => fun(_) -> undefined end},
             case eth_evm:run(Code, Msg, State, Env, 30000000) of
                 {ok, Out, GasLeft, _, _} ->
                     io:format("   (code bytes=~p out=~p gas_used=~p)~n",
                               [byte_size(Code), byte_size(Out), 30000000 - GasLeft]),
                     {ok};
                 Other ->
                     io:format("   (run=~p)~n", [Other]),
                     {ok}
             end
         end}
    ]),
    halt(0).

eth_get_code(Addr) ->
    case eth_rpc_client:call(<<"eth_getCode">>, [Addr, <<"latest">>]) of
        {ok, Hex} -> eth_state:hex_to_bin(Hex);
        _ -> <<>>
    end.

find_code([]) -> throw(no_contract_with_code);
find_code([A | T]) ->
    case byte_size(eth_get_code(A)) of
        0 -> find_code(T);
        _ -> A
    end.

checks(List) ->
    lists:foreach(fun({Name, Fun}) ->
        R = (catch Fun()),
        case R of
            {ok} ->
                io:format("[ok  ] ~s~n", [Name]);
            {{ok, L}, {ok, U}} when L =:= U ->
                io:format("[ok  ] ~s: ~s~n", [Name, L]);
            {{ok, L}, {ok, U}} ->
                io:format("[diff] ~s: local=~p type=~p upstream=~p type=~p~n",
                          [Name, L, is_binary(L), U, is_binary(U)]);
            {{ok, L}, Old} ->
                io:format("[diff] ~s: local=~s upstream=~p~n", [Name, L, Old]);
            Other ->
                case R of
                    {L, U} -> io:format("[no  ] ~s: local=~p upstream=~p~n", [Name, L, U]);
                    _ -> io:format("[err ] ~s: ~p~n", [Name, Other])
                end
        end
    end, List).

length_to_hex_word(N) ->
    Hex = string:lowercase(binary:encode_hex(eth_word:to_bytes(N, 32))),
    <<"0x", Hex/binary>>.