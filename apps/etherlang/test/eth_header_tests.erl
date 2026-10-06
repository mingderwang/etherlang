-module(eth_header_tests).

-export([sepolia_block/0]).

-include_lib("eunit/include/eunit.hrl").

%% A real Sepolia header (block 0xb2dd74) as returned by eth_getBlockByNumber
%% with full=false. Its keccak(RLP(fields)) must equal the claimed hash.
sepolia_block() ->
    #{<<"parentHash">> =>
          <<"0xaa8a87aa293f5c511e07e472ecaccac27188e68c37651e62158c4a4d6b783740">>,
      <<"sha3Uncles">> =>
          <<"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347">>,
      <<"miner">> => <<"0x3826539cbd8d68dcf119e80b994557b4278cec9f">>,
      <<"stateRoot">> =>
          <<"0x94ce3a7f35c302150e768984684beeeb67a6ae56d9b22f7db5eac272d9fe4e2b">>,
      <<"transactionsRoot">> =>
          <<"0xae24ff340100b3d4a07599c556e19a81ebc45bb2810d41434fc616e89fdb4fd9">>,
      <<"receiptsRoot">> =>
          <<"0x07c5675591b41c5a60594096854d52a01f14f1386f8f5f0aa0b2fee4c8c4392f">>,
      <<"logsBloom">> =>
          <<"0x94a619b508c320354aaa2d2bb2ad165a5878e37a6268d5de8edc3e3468060952"
            "aa8a49b421b2301050b1ed2680c2df330462903ff6f5b025cca24b0ce8b56cc2"
            "72161f4336b1d0213325accef76e0639028c058b719c691747ff1cebde8cb708b"
            "b60d982d23372f442818022fbf8cc2342aeae38b26c8648302450f2c0acb2d6a0"
            "d65855115c4b19539bb119a26f5ed541bc5a29f11480ad19068eee8b80b90beaa"
            "be3e0a09c51c34552aff8152b4f28d496fc380e8740828b338388f4084497ce6c"
            "db222d1831be94cec5273bd3346853b0726486898353cd00433348196a6161d147"
            "0ac4a44109180f126c9e02de08bac85f2fbaa802cfb1df0a2701910a65">>,
      <<"difficulty">> => <<"0x0">>,
      <<"number">> => <<"0xb2dd74">>,
      <<"gasLimit">> => <<"0x3938700">>,
      <<"gasUsed">> => <<"0x2698ef0">>,
      <<"timestamp">> => <<"0x6aab8de0">>,
      <<"extraData">> => <<"0x626573752032362e392d646576656c6f702d64393763626436">>,
      <<"mixHash">> =>
          <<"0x29d38dbecc25ffffa9a58f2ac648e3211539ba743067a843577805523cecf587">>,
      <<"nonce">> => <<"0x0000000000000000">>,
      <<"baseFeePerGas">> => <<"0x3deef742">>,
      <<"withdrawalsRoot">> =>
          <<"0xfbb6fbfdc4d9114b8f69f79b0ab5b961c7c449dc86ec12f39aefcde305c34483">>,
      <<"blobGasUsed">> => <<"0x60000">>,
      <<"excessBlobGas">> => <<"0xc82d651">>,
      <<"parentBeaconBlockRoot">> =>
          <<"0xa1cc8b086b4e2364d054eb585da55fe7e646d42f170819128406fb95605999bd">>,
      <<"requestsHash">> =>
          <<"0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>,
      <<"hash">> =>
          <<"0xd79af795480c8bd40f009e5ff99a08675a5a44d3148f0a55070aaeb085f682e9">>}.

%% **This was a comprehension over a hand-written `hexval/1`** -- the fourth shape of hex
%% decoder this repository has grown, and the only one that is a binary comprehension
%% rather than a clause list, which is why a guard looking for `hex_to_bin(` missed it and
%% why `eth_hex_owners_tests` lists `hexval(` as well. It is the same decoder: `<<A, B>> <=
%% Hex` walks the string two characters at a time and `hexval/1` turns each into a nibble.
unhex(Hex) -> eth_hex:must_decode_bytes(Hex).

real_sepolia_header_test() ->
    B = sepolia_block(),
    {ok, H} = eth_header:hash(B),
    ?assertEqual(unhex(maps:get(<<"hash">>, B)), H),
    ?assertEqual({ok, maps:get(<<"hash">>, B)}, eth_header:verify(B)),
    ?assertEqual({ok, maps:get(<<"hash">>, B)}, eth_header:hex_hash(B)).

verify_rejects_tampered_field_test() ->
    B = sepolia_block(),
    Tampered = B#{<<"gasUsed">> => <<"0x2698ef1">>},
    ?assertMatch({error, {bad_block_hash, _, _}}, eth_header:verify(Tampered)).

verify_accepts_hashless_block_test() ->
    B = maps:remove(<<"hash">>, sepolia_block()),
    {ok, Hex} = eth_header:hex_hash(B),
    ?assertEqual({ok, Hex}, eth_header:verify(B)).

missing_field_test() ->
    B = maps:remove(<<"stateRoot">>, sepolia_block()),
    ?assertEqual({error, {missing_header_field, <<"stateRoot">>}}, eth_header:hash(B)).

accessors_test() ->
    B = sepolia_block(),
    ?assertEqual(<<"0xaa8a87aa293f5c511e07e472ecaccac27188e68c37651e62158c4a4d6b783740">>,
                 eth_header:parent_hash(B)),
    ?assertEqual(16#b2dd74, eth_header:number(B)).

%% ---------------------------------------------------------------------------
%% `requestsHash` is the last header field, pinned by a real block
%% ---------------------------------------------------------------------------
%% EIP-7685 does not say where the field sits in the RLP list, so its position is not
%% derivable from the EIP and has to come from somewhere else. It comes from the
%% fixture above, which is a real Sepolia header -- block 11,722,100, timestamp
%% 1,789,629,872, long past Sepolia's Prague activation -- carrying the field and
%% claiming the real hash `0xd79af79...`.
%%
%% I removed the field from `eth_header:header_fields/0` once and made `hash/1` refuse
%% a block carrying it, reasoning that appending it was an invented position. The
%% fixture already in this file is what showed that to be a regression: appending the
%% field **last** reproduces the real hash exactly. Refusing would have left this node
%% unable to hash a real Prague block it had been getting right.
%%
%% I also read the field's value, `0xe3b0c442...`, as SHA-256 of nothing and therefore
%% hand-entered. It is what the network reports, because with EIP-7251 there are no
%% requests to commit to -- and `eth_getBlockByNumber` returns it verbatim. Both halves
%% of that were checked against the RPC rather than against my reading of the EIP,
%% which is the only reason the regression did not ship.

requests_hash_is_the_last_header_field_and_says_so_against_a_real_block_test() ->
    %% The fixture is a Prague header, so this exercises the twenty-first field and
    %% not the Cancun twenty. The Cancun shape is covered by the test above, which is
    %% what makes the two together an assertion about the *order* rather than about a
    %% set of fields.
    ?assertNotEqual(undefined, maps:get(<<"requestsHash">>, sepolia_block())),
    ?assertNotEqual(undefined, maps:get(<<"parentBeaconBlockRoot">>, sepolia_block())),
    ?assertEqual({ok, maps:get(<<"hash">>, sepolia_block())},
                 eth_header:hex_hash(sepolia_block())),
    ?assertMatch({ok, _}, eth_header:verify(sepolia_block())).

a_cancun_shaped_block_has_twenty_fields_and_a_prague_one_twenty_one_test() ->
    %% Removing `requestsHash` is what a Cancun header looks like, and its hash is
    %% *not* the block's -- so the twenty-first field is load-bearing here, which is
    %% the thing a set-membership test would have missed.
    S = maps:remove(<<"requestsHash">>, sepolia_block()),
    {ok, Hash} = eth_header:hash(S),
    ?assertNotEqual(maps:get(<<"hash">>, sepolia_block()), hex0x(Hash)),
    {ok, CancunFields} = eth_header:to_rlp_list(S),
    {ok, PragueFields} = eth_header:to_rlp_list(sepolia_block()),
    ?assertEqual(20, length(CancunFields)),
    ?assertEqual(21, length(PragueFields)).

hex0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.


% ---------------------------------------------------------------------------
% EIP-7843: `slotNumber` is the 22nd header field, pinned by two real blocks
% ---------------------------------------------------------------------------
% **Two fixtures, because one cannot separate "appended last" from "in the right
% place".** A single Amsterdam header pins that the 22-field encoding hashes to its
% claimed value, and it cannot distinguish "appended last" from "appended before
% `requestsHash'" -- both are 22 fields, and only one of them is right. The pre-Amsterdam
% header beside it is the control that makes the claim about *position* rather than about
% *count*: it has no `slotNumber` at all, and it must still hash exactly as claimed. A
% field placed as a fixed 22nd slot would change the hash of every block on every
% network from genesis, and the control is what would say so.
%
% The two blocks are adjacent, and that is the point:
%
% | block | timestamp | `slotNumber` | claimed hash |
% |-------|-----------|--------------|--------------|
% | 11,856,336 | 1791294804 | absent | `0x862fbae1...` |
% | 11,856,337 | 1791294816 | `0xac6000` | `0xa03f956a...` |
%
% 1,791,294,816 is precisely Sepolia's `amsterdamTime`, so **11,856,337 is the first
% Amsterdam block on Sepolia** and 11,856,336 the last Prague one. Both read from
% `eth_getBlockByNumber` with `full=false`; the values are the network's own and were not
% computed here.
%
% `slotNumber` is 11,296,768 against block 11,856,337 -- a slot number is not a block
% number and the two are not interchangeable, which is the reason the field exists.

% Sepolia block 11,856,337: the first with `slotNumber`, and the first at or after
% `amsterdamTime`. Extra data reads `besu 26.9.1`.
amsterdam_block() ->
    #{      <<"parentHash">> => <<"0x862fbae116b7dca00b550ad371540de5ec8f627065bead949809ee6228b8f3eb">>,
      <<"sha3Uncles">> => <<"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347">>,
      <<"miner">> => <<"0x3826539cbd8d68dcf119e80b994557b4278cec9f">>,
      <<"stateRoot">> => <<"0xfa3dce0649b084038be0d2e88b0740fdd50631fc32109c0f7766fa242baf2c39">>,
      <<"transactionsRoot">> => <<"0x4370e25f6d627e5e9efca9cb5405f38c5ae86043e5b400ea92992d51aba12b6c">>,
      <<"receiptsRoot">> => <<"0x636dbd7afafef168dee179457d140e251ddb3c203596d148338d1ee813f1f034">>,
      <<"logsBloom">> =>
          <<"0x8014a800082084804806100090009a2028220011620000168200608488100546c288100801c811022248210a01200222421950128ec100000c2892242226031a711c0551a00a220002602a58404900c0e00002c06600081121030400948540010a20000122284012608548c102604c1830800040e00c22483468a51004090118"
            "a500008009344a0009a080504206014121402041100a20081084004504201641028000810000410a803001480001041e00005000a0d0c1308a40020a02044001490f008601010220003d04004ba2000252120200040880384000800001c0694000d0101900b01810ac4814002ca0800450001800884500400207080200010208">>,
      <<"difficulty">> => <<"0x0">>,
      <<"number">> => <<"0xb4e9d1">>,
      <<"gasLimit">> => <<"0x3938700">>,
      <<"gasUsed">> => <<"0xd1dda4">>,
      <<"timestamp">> => <<"0x6ac4fd60">>,
      <<"extraData">> => <<"0x626573752032362e392e31">>,
      <<"mixHash">> => <<"0x4ba9dfc9ce033a38b9f2d6d4b549e4b3a398dbcd8dd7c514d944f42c9a1a4405">>,
      <<"nonce">> => <<"0x0000000000000000">>,
      <<"baseFeePerGas">> => <<"0x3d7386e5">>,
      <<"withdrawalsRoot">> => <<"0x5127063b341e2ad8b2236316204563d3025b6b9b61290fec666a0a0bba4286a7">>,
      <<"blobGasUsed">> => <<"0x80000">>,
      <<"excessBlobGas">> => <<"0xc6e7614">>,
      <<"parentBeaconBlockRoot">> => <<"0xa982af12aa814307469427e140dd62cf6b6cbbcf0539fbab10336132e47b0743">>,
      <<"requestsHash">> => <<"0xec88bf0d3fe6b86b583cf638c5635cb64bc842fee1e220f0e8be964a4d368c15">>,
      <<"blockAccessListHash">> => <<"0xe6048b5d71a01b46691aa7d24238ba7880b789ae42173cab10a041b72e768a55">>,
      <<"slotNumber">> => <<"0xac6000">>,
      <<"hash">> => <<"0xa03f956aeb69d3fa234d9894c4309f4bb089cca9b6440cb45066c9ba39222588">>}.

% Sepolia block 11,856,336: the block immediately before it, and the control.
% It carries every field `requestsHash` introduced and no `slotNumber` at all.
pre_amsterdam_block() ->
    #{      <<"parentHash">> => <<"0x23f39d93782a7abe322c5cb9d7b6593923707bb820c5b60a2036bb8d2249e231">>,
      <<"sha3Uncles">> => <<"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347">>,
      <<"miner">> => <<"0x3826539cbd8d68dcf119e80b994557b4278cec9f">>,
      <<"stateRoot">> => <<"0xff66f5ce6133dcfeecde6a245f25a90a45a9fbe9f8ffbd9bcd91dd2ddfa8f661">>,
      <<"transactionsRoot">> => <<"0xe2abd363466813991b91239e7b769cf8affbeb04735a882ff88421c307c104d4">>,
      <<"receiptsRoot">> => <<"0xe07bc5ed71c60394a4ba3703b036d77590615b8bcbd75e8d73a856d71c119c1e">>,
      <<"logsBloom">> =>
          <<"0x0038a00c000010205058a0b88c0070c31142035408064a99218500a6260a040208cc280008424100f380b01398a08050610992064056100201410200007c35341011314401804360040ac88b8078002015c55748932d802080431000840800000e20100222680010098500450350094412408050e4ba250005180898008d00c6"
            "8ad02085a1556840a109091423846c8000003c8d0402800c910c01438480062088088020d010049a00480160486140bc060c2100204810c00a70273822a244a3d2c00802040216401c0120034070024321144232a20c001540e1250002166a854520010042826840881210092507a812a04006001843604892c10c00011b8118">>,
      <<"difficulty">> => <<"0x0">>,
      <<"number">> => <<"0xb4e9d0">>,
      <<"gasLimit">> => <<"0x3938700">>,
      <<"gasUsed">> => <<"0x393635d">>,
      <<"timestamp">> => <<"0x6ac4fd54">>,
      <<"extraData">> => <<"0x626573752032362e392e31">>,
      <<"mixHash">> => <<"0x818202465d3aef939ea44285c3eb77f757d0898c075fdcedbb147650300d0ecd">>,
      <<"nonce">> => <<"0x0000000000000000">>,
      <<"baseFeePerGas">> => <<"0x36a00d50">>,
      <<"withdrawalsRoot">> => <<"0xe74d8b2f718b3fd5b3477417808731174c93ed89476383f245432e01731df27e">>,
      <<"blobGasUsed">> => <<"0x120000">>,
      <<"excessBlobGas">> => <<"0xc787614">>,
      <<"parentBeaconBlockRoot">> => <<"0x3bf00d7b97294e86fe1efe26971e3b250bfaa5c3de6ab6088b06dac10a62d2aa">>,
      <<"requestsHash">> => <<"0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855">>,
      <<"hash">> => <<"0x862fbae116b7dca00b550ad371540de5ec8f627065bead949809ee6228b8f3eb">>}.

real_amsterdam_header_hashes_as_claimed_test() ->
    % The whole point of the fixture. `eth_header:hash/1` has to reproduce the network's
    % own value with `slotNumber` present, or this node cannot recognise an Amsterdam
    % block and the Engine API path fails at the first hash comparison.
    ?assertEqual({ok, maps:get(<<"hash">>, amsterdam_block())},
                 eth_header:hex_hash(amsterdam_block())),
    ?assertMatch({ok, _}, eth_header:verify(amsterdam_block())).

slot_number_is_the_twenty_third_header_field_test() ->
    ?assertNotEqual(undefined, maps:get(<<"slotNumber">>, amsterdam_block())),
    {ok, Fields} = eth_header:to_rlp_list(amsterdam_block()),
    ?assertEqual(23, length(Fields)),
    % **The last element is the slot number itself**, and RLP-encodes as a quantity:
    % `0xac6000` is 11,296,768 and must not appear as a 32-byte big-endian word, which is
    % what a `data` kind would produce and would change the hash.
    ?assertEqual(16#ac6000, lists:last(Fields)).

a_pre_amsterdam_header_is_unaffected_by_the_slot_number_field_test() ->
    % The control. This block has no `slotNumber`, so the 21-field encoding must still be
    % what reproduces its hash -- which is the evidence that the field is *appended*
    % rather than slotted in at a fixed position.
    ?assertEqual(undefined, maps:get(<<"slotNumber">>, pre_amsterdam_block(), undefined)),
    {ok, Fields} = eth_header:to_rlp_list(pre_amsterdam_block()),
    ?assertEqual(21, length(Fields)),
    ?assertEqual({ok, maps:get(<<"hash">>, pre_amsterdam_block())},
                 eth_header:hex_hash(pre_amsterdam_block())).

dropping_the_slot_number_from_an_amsterdam_block_changes_its_hash_test() ->
    % Without this the two fixtures above would also be satisfied by a `slotNumber` that
    % is read and then discarded, since the count assertions would still hold only if it
    % were counted -- so this pins that it *participates* in the encoding rather than
    % merely being present in the list.
    S = maps:remove(<<"slotNumber">>, amsterdam_block()),
    ?assertNotEqual(maps:get(<<"hash">>, amsterdam_block()),
                     element(2, eth_header:hex_hash(S))).


%% ---------------------------------------------------------------------------
%% `data` versus `qty` for a hash field is invisible on a hash whose first byte
%% is non-zero, so it needs its own fixture
%% ---------------------------------------------------------------------------
%% **Three of the four injections for these two fields did not need this test and one
%% could not be caught without it.** Switching `blockAccessListHash` from `opt_data` to
%% `opt_qty` left the whole module green, and the reason is worth stating because it is the
%% reason the mistake is easy to make: `0xe6048b5d...` and the integer `0xe6048b5d...` have
%% the **same RLP encoding**, because an RLP integer is minimal big-endian and this value
%% has no leading zero byte to strip. Every hash in the Amsterdam fixture happens to start
%% with a non-zero byte -- which is not luck, it is what a uniform 32-byte field usually
%% looks like -- so "the hashes the tests use cannot tell these two apart" is a statement
%% about the fixture and not about the code.
%%
%% They differ in two places, and both are consensus:
%%
%% * **Encoding.** A quantity is a minimal integer, so a hash beginning `0x00` would RLP as
%%   31 bytes under `qty` and 32 under `data`, and the block hash would differ.
%% * **Round-trip.** `from_rlp/1` dispatches on the kind to produce `"0x..."` (data) or
%%   `"0x0"` (quantity), so the wrong kind hands the payload decoder a 32-byte hash it then
%%   re-encodes as a number.
%%
%% The value below is the fixture's own `blockAccessListHash` with its first byte set to
%% to zero** -- still 32 bytes; I first wrote a zero *prefixed* to a 32-byte
%% value, which is 33, and `byte_size/1` caught it. **The block no longer hashes to its claimed value and is not claimed to** -- this
%% is a test about the *kind*, and a fixture about a rule needs a value that exercises the
%% rule, not one that also reproduces a hash.

a_header_hash_field_is_a_fixed_width_string_and_not_a_quantity_test() ->
    %% Leading zero, which is the whole reason this fixture exists.
    B = (amsterdam_block())#{
           <<"blockAccessListHash">> =>
               <<"0x00048b5d71a01b46691aa7d24238ba7880b789ae42173cab10a041b72e768a55">>},
    {ok, Fields} = eth_header:to_rlp_list(B),
    ?assertEqual(23, length(Fields)),
    %% Field 22 of 23 is `blockAccessListHash`; field 23 is `slotNumber`.
    Hash = lists:nth(22, Fields),
    ?assertMatch(<<_:32/binary>>, Hash),
    ?assertEqual(32, byte_size(Hash)),
    ?assertEqual(16#0, binary:at(Hash, 0)),
    %% **The encoding difference.** A 32-byte RLP string is `0xa0` followed by 32 bytes;
    %% a minimal integer with a leading zero stripped would be `0x9f` and 31 bytes. If the
    %% kind were `qty` the element would be an integer and `eth_rlp:encode/1` would emit
    %% the shorter form, so this is the assertion that actually discriminates.
    ?assertEqual(<<16#a0, Hash/binary>>, eth_rlp:encode(Hash)).
