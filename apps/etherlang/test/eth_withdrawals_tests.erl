%% EIP-4895 withdrawals, checked against real Sepolia blocks.
%%
%% The withdrawals root was previously computed as an SSZ hash-tree-root. That
%% is a plausible 32-byte value which no other client produces: the root is
%% actually a Merkle-Patricia trie keyed by list position, exactly like the
%% transactions root. Nothing about the wrong version is detectably wrong by
%% inspection -- it just never matches a real block -- so these tests are
%% anchored to roots taken from the chain.
%%
%% Vectors, both from Sepolia:
%%
%%   block 0x2da3f2 (ts 1677559908, 2 withdrawals, first post-Shanghai ramp)
%%     withdrawalsRoot 0x38602dba4be838ba8381b6b6e96b83cac6073e4149b660516c5a9aba621c6bbc
%%
%%   block 0x6dc0c0 (ts 1696042216, 16 withdrawals -- the steady state)
%%     withdrawalsRoot 0x516e85381f6571e00bfc4d8bc81e579ad40c0402b2f73c0c316342a5c3d008f3

-module(eth_withdrawals_tests).

-include_lib("eunit/include/eunit.hrl").

%% Empty withdrawals list -> the canonical empty-trie root. This is the value
%% that distinguishes the trie construction from the SSZ one, which would give
%% 0x792930bbd5baac43bcc798ee49aa8185ef76bb3b44ba62b91d86ae569e4bb535.
empty_list_is_the_empty_trie_root_test() ->
    ?assertEqual(<<16#56, 16#e8, 16#1f, 16#17, 16#1b, 16#cc, 16#55, 16#a6,
                   16#ff, 16#83, 16#45, 16#e6, 16#92, 16#c0, 16#f8, 16#6e,
                   16#5b, 16#48, 16#e0, 16#1b, 16#99, 16#6c, 16#ad, 16#c0,
                   16#01, 16#62, 16#2f, 16#b5, 16#e3, 16#63, 16#b4, 16#21>>,
                 eth_fork_schedule:withdrawals_root([])).

%% Sepolia 0x2da3f2.
two_withdrawals_root_test() ->
    Ws = [{373, 1571, <<16#388ea662ef2c223ec0b047d41bf3c0f362142ad5:160>>, 963},
          {374, 1572, <<16#388ea662ef2c223ec0b047d41bf3c0f362142ad5:160>>, 963}],
    ?assertEqual(<<"0x38602dba4be838ba8381b6b6e96b83cac6073e4149b660516c5a9aba621c6bbc">>,
                 root_hex(Ws)).

%% Sepolia 0x6dc0c0, the 16-withdrawal steady state. A short list and a full
%% one exercise different branches of the trie, so agreeing on only one of them
%% would not be enough.
sixteen_withdrawals_root_test() ->
    Ws = [{16#401b6c9, 16#393, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6ca, 16#39f, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6cb, 16#3a0, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6cc, 16#3a1, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6cd, 16#3a6, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6ce, 16#3a7, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6cf, 16#3a9, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d0, 16#3ac, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d1, 16#3ba, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d2, 16#3be, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d3, 16#3c1, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d4, 16#3c3, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d5, 16#3c6, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d6, 16#3c8, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d7, 16#3c9, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#e5c},
          {16#401b6d8, 16#3d7, <<16#e276bc378a527a8792b353cdca5b5e53263dfb9e:160>>, 16#ac5}],
    ?assertEqual(<<"0x516e85381f6571e00bfc4d8bc81e579ad40c0402b2f73c0c316342a5c3d008f3">>,
                 root_hex(Ws)).

%% The wire shape must give the same root as the internal shape. A payload
%% arriving from the consensus layer carries string keys and hex quantities, and
%% silently reading a missing field as 0 would produce a wrong root that still
%% looks like a hash.
json_and_internal_shapes_agree_test() ->
    Internal = eth_fork_schedule:withdrawals_root(
                 [#{index => 373, validatorIndex => 1571,
                    address => <<16#38, 16#8e, 16#a6, 16#62, 16#ef, 16#2c, 16#22,
                               16#3e, 16#c0, 16#b0, 16#47, 16#d4, 16#1b, 16#f3,
                               16#c0, 16#f3, 16#62, 16#14, 16#2a, 16#d5>>,
                    amount => 963}]),
    FromJson = eth_fork_schedule:withdrawals_root(
                 [#{<<"index">> => <<"0x175">>,
                    <<"validatorIndex">> => <<"0x623">>,
                    <<"address">> => <<"0x388ea662ef2c223ec0b047d41bf3c0f362142ad5">>,
                    <<"amount">> => <<"0x3c3">>}]),
    ?assertEqual(Internal, FromJson).

%% The address must reach RLP as 20 raw bytes. Passing the "0x"-prefixed string
%% through would encode 21 bytes and commit to something no other client
%% computes, so this pins the normalisation.
address_is_twenty_raw_bytes_test() ->
    Root = eth_fork_schedule:withdrawals_root(
             [#{index => 1, validatorIndex => 1,
                address => <<"0x0000000000000000000000000000000000000001">>,
                amount => 1}]),
    Same = eth_fork_schedule:withdrawals_root(
             [#{index => 1, validatorIndex => 1,
                address => <<16#01:160>>,
                amount => 1}]),
    ?assertEqual(Same, Root),
    %% And it differs from the value a 21-byte RLP string would produce, which
    %% is the bug this guards.
    TwentyOne = eth_rlp:encode([1, 1, <<"0x0000000000000000000000000000000000000001">>, 1]),
    Twenty = eth_rlp:encode([1, 1, <<16#01:160>>, 1]),
    ?assertNotEqual(Twenty, TwentyOne).

%% The key is the list position, not the withdrawal's own index. Withdrawing at
%% positions 0 and 1 whose `index` fields are 373 and 374 must be committed the
%% same way as positions 0 and 1 carrying any other indices, and differently from
%% a list keyed by those index values.
key_is_position_not_withdrawal_index_test() ->
    A = <<16#01:160>>,
    ByPosition = eth_fork_schedule:withdrawals_root(
                   [#{index => 373, validatorIndex => 1, address => A, amount => 1},
                    #{index => 374, validatorIndex => 2, address => A, amount => 2}]),
    OtherIndices = eth_fork_schedule:withdrawals_root(
                     [#{index => 7, validatorIndex => 1, address => A, amount => 1},
                      #{index => 9, validatorIndex => 2, address => A, amount => 2}]),
    %% The index is part of the value, so the roots still differ...
    ?assertNotEqual(ByPosition, OtherIndices),
    %% ...but the key is the position, so reordering the list changes the root
    %% even when the multiset of withdrawals is identical.
    Reversed = lists:reverse(
                 [#{index => 373, validatorIndex => 1, address => A, amount => 1},
                  #{index => 374, validatorIndex => 2, address => A, amount => 2}]),
    ?assertNotEqual(ByPosition,
                    eth_fork_schedule:withdrawals_root(Reversed)).

%% EIP-4895 allows at most 16 withdrawals per payload. The root stays well
%% defined past that by truncating, but a caller must reject the payload rather
%% than accept the truncated commitment.
over_cap_list_is_truncated_test() ->
    A = <<16#01:160>>,
    Sixteen = [#{index => I, validatorIndex => I, address => A, amount => 1}
               || I <- lists:seq(0, 15)],
    Seventeen = Sixteen ++ [#{index => 16, validatorIndex => 16,
                              address => A, amount => 1}],
    ?assertEqual(eth_fork_schedule:withdrawals_root(Sixteen),
                 eth_fork_schedule:withdrawals_root(Seventeen)).

%% eth_block:withdrawals_root/0 is what a locally built block stamps into its
%% header, so it has to agree with the general function.
block_default_matches_empty_list_test() ->
    ?assertEqual(eth_fork_schedule:withdrawals_root([]),
                 eth_block:withdrawals_root()).

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

%% root_hex/1 takes {index, validatorIndex, address, amount} tuples so the
%% vectors below read as the four fields of a withdrawal rather than as map
%% syntax; the function under test takes maps, as the wire delivers them.
root_hex(Ws) ->
    Root = eth_fork_schedule:withdrawals_root([to_map(W) || W <- Ws]),
    <<"0x", (string:lowercase(binary:encode_hex(Root)))/binary>>.

to_map({Index, Validator, Address, Amount}) ->
    #{index => Index, validatorIndex => Validator,
      address => Address, amount => Amount}.
