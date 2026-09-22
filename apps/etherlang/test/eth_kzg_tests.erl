-module(eth_kzg_tests).

-include_lib("eunit/include/eunit.hrl").

-define(R, 16#73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001).
-define(OK, {ok, <<0:240, 16#1000:16, ?R:256>>, 50000}).

%% exec-spec-tests `test_valid_inputs` fixtures (Cancun point-evaluation 0x0A).
%% mainnet_1: real Mainnet tx 0xcb3dc8..., field order versioned_hash|z|y|C|π.

kzg_mainnet_1_success_test() ->
    Data = <<16#018156B94FE9735E573BAB36DAD05D60FEB720D424CCD20AAF719343C31E4246:256,
             16#019123BCB9D06356701F7BE08B4494625B87A7B02EDC566126FB81F6306E915F:256,
             16#6C2EB1E94C2532935B8465351BA1BD88EABE2B3FA1AADFF7D1CD816E8315BD38:256,
             16#A9546D41993E10DF2A7429B8490394EA9EE62807BAE6F326D1044A51581306F58D4B9DFD5931E044688855280FF3799E:384,
             16#A2EA83D9391E0EE42E0C650ACC7A1F842A7D385189485DDB4FD54ADE3D9FD50D608167DCA6C776AAD4B8AD5C20691BFE:384>>,
    ?assertEqual(?OK, eth_kzg:point_evaluation(Data)).

kzg_in_bounds_z_success_test() ->
    %% z = r-1, y = 0, commitment/proof at infinity -> p(z)==0 for all z.
    Inf = <<16#C0:8, 0:376>>,
    VH = eth_kzg:versioned_hash(Inf),
    Data = <<VH/binary, (?R - 1):256, 0:256, Inf/binary, Inf/binary>>,
    ?assertEqual(?OK, eth_kzg:point_evaluation(Data)).

kzg_short_input_unsupported_test() ->
    ?assertEqual(unsupported, eth_kzg:point_evaluation(<<1, 2, 3>>)).

kzg_bad_versioned_hash_test() ->
    Inf = <<16#C0:8, 0:376>>,
    VH = <<(binary:at(eth_kzg:versioned_hash(Inf), 0) bxor 1):8,
           (binary:part(eth_kzg:versioned_hash(Inf), 1, 31))/binary>>,
    Data = <<VH/binary, (?R - 1):256, 0:256, Inf/binary, Inf/binary>>,
    ?assertEqual(unsupported, eth_kzg:point_evaluation(Data)).

kzg_wrong_y_fails_test() ->
    Data = <<16#018156B94FE9735E573BAB36DAD05D60FEB720D424CCD20AAF719343C31E4246:256,
             16#019123BCB9D06356701F7BE08B4494625B87A7B02EDC566126FB81F6306E915F:256,
             16#6C2EB1E94C2532935B8465351BA1BD88EABE2B3FA1AADFF7D1CD816E8315BD39:256,
             16#A9546D41993E10DF2A7429B8490394EA9EE62807BAE6F326D1044A51581306F58D4B9DFD5931E044688855280FF3799E:384,
             16#A2EA83D9391E0EE42E0C650ACC7A1F842A7D385189485DDB4FD54ADE3D9FD50D608167DCA6C776AAD4B8AD5C20691BFE:384>>,
    ?assertEqual(unsupported, eth_kzg:point_evaluation(Data)).