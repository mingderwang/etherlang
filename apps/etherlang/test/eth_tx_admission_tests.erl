%% -*- erlang -*-
%% Admission rules this node did not have: EIP-3607, EIP-3860, and EIP-1559's fee-field
%% rule for type-4 transactions.
%%
%% All three were found the same way -- the corpus reporting
%% `expected_rejection_not_raised', which means the node **admitted a transaction every
%% other client refuses**. That is the most serious class of defect in this project: a
%% node that admits an invalid transaction will import a block containing one.
%%
%% **Every test that expects a transaction to be accepted is signed.** The first version
%% of this file built unsigned maps and asserted `?assertEqual(ok, eth_tx:validate(...))`,
%% and every one of them failed with `{error, bad_signature}` -- which is a refusal, so a
%% test written as `?assertMatch({error, _}, ...)` would have passed against a validator
%% that rejected everything. The signature check sits at step 13 of 16, *after* the two
%% new rules, so a test that omits it is testing the signature and nothing else.
-module(eth_tx_admission_tests).

-include_lib("eunit/include/eunit.hrl").

%% A 20-byte address. It was the integer `16#...00ff' in the first version, so
%% `eth_hex:encode_bytes/1' encoded one byte and the transaction was refused
%% `invalid_to' -- again a refusal, which is what an unasserted shape looks like.
-define(PROBE, <<0:152, 16#ff>>).

%% ---------------------------------------------------------------------------
%% EIP-3860: a creation transaction's init code may not exceed 2 * MAX_CODE_SIZE.

initcode_limit_is_two_code_sizes_from_shanghai_test() ->
    ?assertEqual(49152, eth_fork_schedule:max_initcode_size(shanghai)),
    ?assertEqual(49152, eth_fork_schedule:max_initcode_size(prague)),
    %% EIP-170's MAX_CODE_SIZE doubled, so the relation is checkable rather than a
    %% transcribed number.
    ?assertEqual(2 * eth_fork_schedule:max_code_size(shanghai),
                 eth_fork_schedule:max_initcode_size(shanghai)).

there_is_no_initcode_limit_before_shanghai_test() ->
    %% **Paris, not Cancun.** The first version asserted `cancun' and it answered 49,152,
    %% correctly: Cancun is *after* Shanghai, so `at_least(cancun, shanghai)' is true. The
    %% test was wrong about the fork order and read like a fork-schedule bug, which is what
    %% checking would have prevented.
    ?assertEqual(infinity, eth_fork_schedule:max_initcode_size(paris)),
    ?assertEqual(infinity, eth_fork_schedule:max_initcode_size(berlin)),
    ?assertEqual(49152, eth_fork_schedule:max_initcode_size(cancun)).

%% The corpus's six fixtures are all **exactly one byte over**, which is the boundary that
%% matters and the one a `<' / `=<' slip moves.
initcode_of_49152_is_accepted_and_49153_is_refused_test() ->
    Priv = eth_secp256k1:generate_key(),
    AtLimit = signed(Priv, #{to => <<>>, input => blob(49152), gas => 9000000}),
    OverLimit = signed(Priv, #{to => <<>>, input => blob(49153), gas => 9000000}),
    ?assertEqual(ok, eth_tx:validate(AtLimit, #{fork => shanghai})),
    ?assertEqual({error, initcode_size_exceeded},
                 eth_tx:validate(OverLimit, #{fork => shanghai})).

a_large_creation_is_still_valid_before_shanghai_test() ->
    %% Not a Shanghai rule applied everywhere. Before the fork there was no limit, and
    %% refusing 49,153 bytes of init code on Cancun would be this node inventing a rule
    %% the chain does not have.
    Priv = eth_secp256k1:generate_key(),
    Tx = signed(Priv, #{to => <<>>, input => blob(49153), gas => 9000000}),
    ?assertEqual(ok, eth_tx:validate(Tx, #{fork => paris})).

a_creation_with_no_data_is_fine_test() ->
    Priv = eth_secp256k1:generate_key(),
    ?assertEqual(ok, eth_tx:validate(signed(Priv, #{to => <<>>}), #{fork => shanghai})).

%% The limit is on **init code**, so a call carrying the same bytes is not a creation and
%% is not subject to it. If this fails, the check is on `data' rather than on
%% `IsCreate anddata'.
a_call_with_the_same_bytes_is_not_affected_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = signed(Priv, #{input => blob(60000), gas => 9000000}),
    ?assertEqual(ok, eth_tx:validate(Tx, #{fork => shanghai})).

%% ---------------------------------------------------------------------------
%% EIP-3607: a transaction whose sender has code is invalid, from London.

sender_must_be_an_eoa_from_london_test() ->
    ?assertEqual(true, eth_fork_schedule:sender_must_be_eoa(london)),
    ?assertEqual(true, eth_fork_schedule:sender_must_be_eoa(cancun)),
    %% Berlin is pre-London so the rule is off; Paris is *after* London so it is on --
    %% asserted because the first version claimed otherwise and was wrong about the order
    %% rather than about the rule.
    ?assertEqual(false, eth_fork_schedule:sender_must_be_eoa(berlin)),
    ?assertEqual(true, eth_fork_schedule:sender_must_be_eoa(paris)).

%% **One byte is code.** All eight of the corpus's fixtures carry `code = 0x00` -- a single
%% `STOP'. A rule written as "does the sender have a *contract*" is not this rule, and an
%% implementation that treated a one-byte code as no code would not reproduce the
%% corpus's own expectation.
a_sender_with_one_byte_of_code_is_refused_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = sender_of(signed(Priv, #{})),
    Ctx = #{fork => prague, code_of => code_for(Sender, <<0>>)},
    ?assertEqual({error, sender_not_eoa}, eth_tx:validate(signed(Priv, #{}), Ctx)).

an_eoa_sender_is_accepted_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = sender_of(signed(Priv, #{})),
    Ctx = #{fork => prague, code_of => code_for(Sender, <<>>)},
    ?assertEqual(ok, eth_tx:validate(signed(Priv, #{}), Ctx)).

%% An account that does not exist has no code, and the corpus's fixtures include a sender
%% the fixture never funds. Getting this wrong refuses the first transaction of every new
%% account, which is most of real traffic.
an_absent_sender_is_an_eoa_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = sender_of(signed(Priv, #{})),
    Ctx = #{fork => prague, code_of => code_for(Sender, undefined)},
    ?assertEqual(ok, eth_tx:validate(signed(Priv, #{}), Ctx)).

before_london_a_contract_sender_is_fine_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = sender_of(signed(Priv, #{})),
    Ctx = #{fork => berlin, code_of => code_for(Sender, <<0>>)},
    ?assertEqual(ok, eth_tx:validate(signed(Priv, #{}), Ctx)).

%% EIP-7702's delegation designator is *code*, so a delegated account is refused by this
%% rule. The corpus's eight fixtures are exactly that case: a type-2 transaction with an
%% authorization list whose sender holds `0x00'.
a_delegated_sender_is_refused_because_a_delegation_is_code_test() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = sender_of(signed(Priv, #{})),
    Delegation = <<16#ef, 16#01, 0:196>>,
    Ctx = #{fork => prague, code_of => code_for(Sender, Delegation)},
    ?assertEqual({error, sender_not_eoa}, eth_tx:validate(signed(Priv, #{}), Ctx)).

%% A context with no `code_of` cannot answer the question. It must not refuse everything --
%% `eth_txpool:pool_ctx/0' carries no readers at all and would then reject every pooled
%% transaction -- so it does not. This pins which of the two it does, so the choice is
%% deliberate rather than an accident of a `case` clause.
a_context_that_cannot_read_code_does_not_refuse_test() ->
    Priv = eth_secp256k1:generate_key(),
    ?assertEqual(ok, eth_tx:validate(signed(Priv, #{}), #{fork => prague})).

%% ---------------------------------------------------------------------------
%% EIP-1559's fee-field rule, which a type-4 transaction was skipping entirely.

a_type_4_transaction_is_bound_by_the_1559_fee_fields_test() ->
    %% The corpus's fixture: maxPriorityFeePerGas 8 against maxFeePerGas 7, base fee 7.
    %% `fee_fields_ok/4' had no `eip7702' clause, so a type-4 transaction fell to the
    %% legacy `gasPrice >= 0' branch -- and a type-4 transaction has no `gasPrice', so
    %% `field/3' supplied 0 and **every** fee-field rule was skipped for type 4.
    %%
    %% No signature is needed here and that is not a shortcut: `fee_fields_ok/4' runs
    %% before `valid_signature/1', so this is the position of the check in the sequence
    %% and it is why the corpus saw a fee-field failure rather than a bad signature.
    Base = type4(#{<<"maxFeePerGas">> => <<"0x7">>,
                   <<"maxPriorityFeePerGas">> => <<"0x8">>}),
    ?assertEqual({error, invalid_fee}, eth_tx:validate(Base, #{fork => prague})),
    WithinCap = type4(#{<<"maxFeePerGas">> => <<"0x8">>,
                       <<"maxPriorityFeePerGas">> => <<"0x8">>}),
    ?assertNotEqual({error, invalid_fee}, eth_tx:validate(WithinCap, #{fork => prague})).

a_type_2_transaction_is_still_bound_by_the_same_rule_test() ->
    %% The control. If only the type-4 case were fixed, or the fix were a special case
    %% that somehow bypassed the rule, this would pass with the type-2 rule broken.
    T2 = (type2(#{<<"maxFeePerGas">> => <<"0x7">>,
                  <<"maxPriorityFeePerGas">> => <<"0x8">>}))#{<<"authorizationList">> => []},
    ?assertEqual({error, invalid_fee}, eth_tx:validate(T2, #{fork => london})).

a_type_3_transaction_is_still_bound_by_the_same_rule_test() ->
    T3 = (type3(#{<<"maxFeePerGas">> => <<"0x7">>,
                  <<"maxPriorityFeePerGas">> => <<"0x8">>}))#{
             <<"maxFeePerBlobGas">> => <<"0x1">>,
             <<"blobVersionedHashes">> => [<<1:248>>]},
    ?assertEqual({error, invalid_fee}, eth_tx:validate(T3, #{fork => cancun})).

%% ---------------------------------------------------------------------------
%% The block admission path, because a rule only the harness can reach is a fixture-only
%% improvement.

the_block_admission_path_supplies_a_code_reader_test() ->
    %% `eth_block:validation_ctx/4' is what a block's own transactions are validated
    %% against. Before `code_of' was added there, EIP-3607 could not fire on the real
    %% admission path: `eth_tx:validate/2' treats an absent reader as "cannot answer", so
    %% the node would have refused these transactions in the corpus and imported the same
    %% transaction from a peer.
    ?assertNotEqual(nomatch, string:find(src_of(eth_block), <<"code_of">>)).

%% ---------------------------------------------------------------------------
%% Fixtures

%% A real signed legacy transaction. Every quantity is the **minimal** hex form, because
%% `eth_tx:validate/2' rejects a non-canonical quantity outright and `tx_type/1' answers
%% `unsupported' for `<<"0x02">>' where it matches `<<"0x2">>'. The corpus's own fixtures
%% write `0x02' and reach the validator through `eth_tx:from_rlp/1', the real decode path,
%% which normalises; feeding `validate/2' the fixture's literal hex tests the
%% canonical-encoding rule instead of the rule under test.
signed(Priv, Fields) ->
    Nonce = maps:get(nonce, Fields, 0),
    GasPrice = maps:get(gas_price, Fields, 0),
    Gas = maps:get(gas, Fields, 100000),
    To = maps:get(to, Fields, ?PROBE),
    Value = maps:get(value, Fields, 0),
    Data = maps:get(input, Fields, <<>>),
    ChainId = maps:get(chain_id, Fields, 1),
    Digest = eth_keccak:hash(
               eth_rlp:encode([Nonce, GasPrice, Gas, To, Value, Data, ChainId, 0, 0])),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    #{<<"type">> => <<"0x0">>,
      <<"nonce">> => eth_hex:encode_int(Nonce),
      <<"gasPrice">> => eth_hex:encode_int(GasPrice),
      <<"gas">> => eth_hex:encode_int(Gas),
      <<"to">> => case To of
                      <<>> -> <<"0x">>;
                      _ -> eth_hex:encode_bytes(To)
                  end,
      <<"value">> => eth_hex:encode_int(Value),
      <<"data">> => eth_hex:encode_bytes(Data),
      <<"v">> => eth_hex:encode_int(ChainId * 2 + 35 + V),
      <<"r">> => eth_hex:encode_bytes(<<R:256/unsigned-big>>),
      <<"s">> => eth_hex:encode_bytes(<<S:256/unsigned-big>>)}.

%% The sender, recovered the way `eth_tx:do_sender/1' does it: `keccak' of the recovered
%% public key, last twenty bytes. `eth_tx:signer/1' would be the obvious way to ask and it
%% is **not exported**, so the derivation is repeated here. That is a small duplication and
%% it is the price of the function not being part of the module's interface; recorded
%% because the alternative -- a test that guesses the sender -- would be wrong silently,
%% since `code_of' would then answer for an address nobody is sending from.
sender_of(Tx) ->
    Digest = eth_keccak:hash(
               eth_rlp:encode([q(Tx, <<"nonce">>), q(Tx, <<"gasPrice">>),
                               q(Tx, <<"gas">>), ?PROBE, q(Tx, <<"value">>),
                               <<>>, 1, 0, 0])),
    RecID = q(Tx, <<"v">>) - (1 * 2 + 35),
    {ok, Pub} = eth_secp256k1:recover(Digest, q(Tx, <<"r">>), q(Tx, <<"s">>), RecID),
    binary:part(eth_keccak:hash(Pub), 12, 20).

q(Tx, Key) -> eth_hex:decode(maps:get(Key, Tx)).

%% Answers `Code' for one address and nothing for any other, so a test that gets the
%% sender wrong fails rather than passing on an unrelated account's code.
code_for(Sender, Code) ->
    fun(A) when A =:= Sender -> {ok, Code};
       (_) -> {ok, <<>>}
    end.

type2(Over) ->
    maps:merge(#{<<"type">> => <<"0x2">>,
                 <<"chainId">> => <<"0x1">>,
                 <<"nonce">> => <<"0x0">>,
                 <<"gas">> => <<"0xf4240">>,
                 <<"gasPrice">> => <<"0x0">>,
                 <<"to">> => <<"0x00000000000000000000000000000000000000ff">>,
                 <<"value">> => <<"0x0">>,
                 <<"data">> => <<"0x">>,
                 <<"accessList">> => []}, Over).

type3(Over) ->
    maps:merge(#{<<"type">> => <<"0x3">>,
                 <<"chainId">> => <<"0x1">>,
                 <<"nonce">> => <<"0x0">>,
                 <<"gas">> => <<"0xf4240">>,
                 <<"to">> => <<"0x00000000000000000000000000000000000000ff">>,
                 <<"value">> => <<"0x0">>,
                 <<"data">> => <<"0x">>,
                 <<"accessList">> => []}, Over).

type4(Over) ->
    maps:merge(#{<<"type">> => <<"0x4">>,
                 <<"chainId">> => <<"0x1">>,
                 <<"nonce">> => <<"0x0">>,
                 <<"gas">> => <<"0xf4240">>,
                 <<"to">> => <<"0x00000000000000000000000000000000000000ff">>,
                 <<"value">> => <<"0x0">>,
                 <<"data">> => <<"0x">>,
                 <<"accessList">> => [],
                 <<"authorizationList">> =>
                     [#{<<"chainId">> => <<"0x0">>,
                        <<"address">> => <<"0x00000000000000000000000000000000000000aa">>,
                        <<"nonce">> => <<"0x0">>,
                        <<"yParity">> => <<"0x0">>,
                        <<"r">> => <<1:248>>,
                        <<"s">> => <<1:248>>}]}, Over).

src_of(Mod) ->
    Beam = code:which(Mod),
    Path = filename:join([filename:dirname(filename:dirname(Beam)), "src",
                          atom_to_list(Mod) ++ ".erl"]),
    {ok, Bin} = file:read_file(Path),
    Bin.

blob(N) -> binary:copy(<<0>>, N).
