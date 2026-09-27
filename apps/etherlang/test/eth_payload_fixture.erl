%% Real ExecutionPayload fixtures, taken from Sepolia.
%%
%% One block per header shape the specification has produced: Paris (16 fields),
%% Shanghai (17 -- EIP-4895 appended withdrawalsRoot) and Cancun (19 -- EIP-4844
%% appended blobGasUsed and excessBlobGas). Each carries the block hash and the
%% roots the chain computed, so a test can check this code's arithmetic against
%% the chain's instead of against itself. They were picked for being small -- an
%% empty Paris block, a one-transaction Shanghai block, a three-transaction Cancun
%% block -- because a fixture is only useful if someone can read it.
%%
%% Each payload is a JSON-RPC block in the shape the engine API sends it: the
%% height named `blockNumber', the fee recipient `feeRecipient', the mix hash
%% `prevRandao', and the transactions as raw `TransactionType || TransactionPayload'
%% bytes. The V2/V3 fields appear only where the fork adds them, because which
%% keys are present is exactly what tells the header how many fields it has.
%%
%% The transaction bytes were fetched per hash with `eth_getRawTransactionByHash'
%% rather than taken from the block. The node these came from answers
%% `eth_getBlockByNumber' with *decoded* transaction objects where the
%% specification says raw bytes, and re-encoding those with this codebase's own
%% codec would have made the transactions-root and block-hash checks circular:
%% the code under test agreeing with itself.
%%
%% These tests never fetch. A unit test that reaches for a network fails for
%% reasons that have nothing to do with the code under it, and fails only when
%% the network is having a bad day.
-module(eth_payload_fixture).

-export([paris/0, shanghai/0, cancun/0, blobs/0, all/0]).

%% (Fork, Fixture) for each block.
all() -> [{paris, paris()}, {shanghai, shanghai()}, {cancun, cancun()}].

%% The Cancun payload with non-zero blob gas.
%%
%% This one is *not* a block the network produced, and its block hash does not
%% match, which is why no test checks its hash. It exists to pin a single thing:
%% that the blob quantities reach the block and the header as integers. The real
%% Cancun fixture has `blobGasUsed' and `excessBlobGas' both zero, so a decoder
%% that passed the raw `"0x0"' through undecoded would agree with a correct one on
%% every value available, and the bug would survive a suite that looked thorough.
%% The smallest Cancun block on Sepolia that actually carries blob gas has 73
%% transactions -- 300KB of fixture for two integers -- so the quantities are the
%% real ones from that block (131072 and 27262976) grafted onto a small payload.
blobs() ->
    #{blob_gas_used => 131072,
      excess_blob_gas => 27262976,
      payload => (maps:get(payload, cancun()))#{
                    <<"blobGasUsed">> => <<"0x20000">>,
                    <<"excessBlobGas">> => <<"0x1a00000">>}}.

paris() ->
    #{
      number => 1450507,
      block_hash => <<"0x1eaed4e4506b09be1435ff3641d63742e2eff296664facc6d475e335c423c742">>,
      transactions_root => <<"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421">>,
      withdrawals_root => undefined,
      payload => #{
      <<"baseFeePerGas">> => <<"0x7">>,
      <<"blockHash">> => <<"0x1eaed4e4506b09be1435ff3641d63742e2eff296664facc6d475e335c423c742">>,
      <<"blockNumber">> => <<"0x16220b">>,
      <<"extraData">> => <<"0x">>,
      <<"feeRecipient">> => <<"0x0000000000000000000000000000000000000000">>,
      <<"gasLimit">> => <<"0x1c9c380">>,
      <<"gasUsed">> => <<"0x0">>,
      <<"logsBloom">> => <<"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000">>,
      <<"parentHash">> => <<"0x8d971a07f0289afc9178456409e07612d603023563f9260c1c7f3dc899f277c3">>,
      <<"prevRandao">> => <<"0xb7581ad3810295f1aa4a0e2367e42efa2b94fc961b818a837e5506c8230cce20">>,
      <<"receiptsRoot">> => <<"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421">>,
      <<"stateRoot">> => <<"0x6aec513f042d8568c1a95638600c8bd60ed70054b80d014cb311d8a8637d487b">>,
      <<"timestamp">> => <<"0x62c59cf8">>,
      <<"transactions">> => []
      }
    }.

shanghai() ->
    #{
      number => 3001655,
      block_hash => <<"0x2fbe86266726c9a98cd6dfd54d3b59a16ea2511be506bd5022185f4ce9f0a085">>,
      transactions_root => <<"0x73d129a7218a242b700eadc0f3f2802924b0d3573e2094a246b72b2378d2907d">>,
      withdrawals_root => <<"0xff132ececf9704a829a5fffecb40c68f400f2ed892ed6aabbeec3ff69c4ee90b">>,
      payload => #{
      <<"baseFeePerGas">> => <<"0x7">>,
      <<"blockHash">> => <<"0x2fbe86266726c9a98cd6dfd54d3b59a16ea2511be506bd5022185f4ce9f0a085">>,
      <<"blockNumber">> => <<"0x2dcd37">>,
      <<"extraData">> => <<"0x4e65746865726d696e642d312e31372e30">>,
      <<"feeRecipient">> => <<"0x670b24610df99b1685aeac0dfd5307b92e0cf4d7">>,
      <<"gasLimit">> => <<"0x1c9c380">>,
      <<"gasUsed">> => <<"0x5c92d">>,
      <<"logsBloom">> => <<"0x00000004000000000000000000100000000100000000200000400000000000000000820000800000000000000080000000000800000000000000000400200000000000004000000000000008000000000008000000000000000000000000000000002000000000000000080000004300000000000000000000020010080000000820000000000000000000000000900000002000000000000000000000800000020000000400000000100001000000000400000000004000000000000002000000000002100000000000000000000000000000000000000110000011000000000014400000000000000010000000000000010000000000080000000000000000">>,
      <<"parentHash">> => <<"0xfe920cb873db0d1a62263147d200c1fa3c5e8aed2a8ffc984ae1dc453f864b2c">>,
      <<"prevRandao">> => <<"0x73c259014c36538792ec4498cdb057b4d7b8c9dd0b38ba2efa470ea1365777a5">>,
      <<"receiptsRoot">> => <<"0xbcb4c7c20999b7783a40caa92579033ba5f1b791c5eb73e087eda6fbf5842d02">>,
      <<"stateRoot">> => <<"0x7a0c644ad136a4302dd85f00476ca9b8c7f9fde188d91734e51fae12131e42e3">>,
      <<"timestamp">> => <<"0x63ff9264">>,
      <<"transactions">> => [
         <<"0x02f90a9683aa36a78204fa84b2d05e0084b2d05e0b835b8d8094d194a706e49750e9bfd77f2fc067f10e1c71921380b90a24b1dc65a400013c211bc9c7e992370e83ef86be197f98e6d6863f216731a47dd1efd984ae0000000000000000000000000000000000000000000000000000000000382701063eceda56fee93ad716620f636c9704f1fc5bf21ace343c0ca8cda1d4d21dd600000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000004a00000000000000000000000000000000000000000000000000000000000000760010001000100000000010101000101010000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000003a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000360000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000cf50000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001a40000000000000000000000000000000000000000000000000000000000000cf50000000000000000000000000000000000000000000000000001d6bffa322ac00000000000000000000000003fa8796d568e743ce8c90ec4723a198d8bcd706c0000000000000000000000000000000000000000000000000000000000000cec0000000000000000000000000000000000000000000000000000000000030d4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004144d269d2c695f6bf9c24be2832b8b6c84b44f1000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000dc2cc710e42857672e7907cf474a69b63b93089f13325c089fce15f0d5c390ef925f70eaf630f08ed694a3dd0c825798c63b891e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000019d7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000015d300ef14cd45f75c79982da7c88c70eba7b1af38f14e2543c82e26aeeef5102e0ccfad31c51cbc98e72fa970e927124a7c1a6dc3683e3ff77aa8db300b6b5101754052cc5b7f938bcbbecfae9a0355e6c8f706d0286d6964d57fd7ee02a1024c933c13ab02c1680e610e32546b9c9be8554cc8bc59c62321e3cc5577ca7d08cb558bac1048486f49696b46753c4bfbb9ce8ad34f529bbe13ce2ebef70535e1127802b8f5dd97370ee6075e878ba2d8f626e691870a4e09108337758bc32801cd76a00468fb8a87fd02665892bcb8b4776c72050e4ea0f41571320799b5133ead652f082d21f2eb39f04fa14cd0ae1f4d54c620ba9074809950cb6285e486c521b9b5465746e383c9a91eb2e5d3b9bbbb07de2ffe57d9c6d319f7b0dc39861d7d3e04230f876d8a1c77e8d977bd23b5184d23b667fb01983b43aa76dc1e005f512eb64608a97f54749e89b9fc5729a3290c300d0bec93aa43741252e6f9449cfe71f5cc8e392fd9b344b3e3295d2e4a14697fdc03881a7baeaa4b0c9e053baa89599b657cefaa3c9bc2d8cb51420b68cc8e3a162f21636dda4e492b05552d0b0bfc982d8980a832899c6a38fad2ff913c779cfa80af5a5639302176e286cd934e91b138096015107c880aa0e894db857b65c5cc3efecad57a0568abdb729be67dc0a08d1c16606b9cc40a2fb90a6e8e985bbf8bdface1a679725c56b4483cf164ebc550c15191a01d2e467e571f1109180de2380d0098c3e68bd86a1d5a01f6ae34b5412da4e9319f67c13dd1b1ff1348805cab914d37681d9e97559a5e7025b6c429bb37f4950ad4991cdf6ad7fea1386a49d360212635d03495e99f554bc53b36ec248afd574afcfee61fd79423add4268df03189e7cb49b243b94f69c5e41ed27661a633bd239c3c54cc0a51fc9588912a4bb3c3f29eef1b1cada28e6ea566000000000000000000000000000000000000000000000000000000000000001519924a097c923394c1b8c4d84f1a128dcf8d311b56429d6f426d01b0aec095b171877232c58f7badd687c84ae7c5e4187e9a723da188a3ea1412f44f304060bb0243d0c1668f3a1ec0da86abfc06951e7fab7e39dd3e6b79a2edd8fca43c3faa22bd4712009d3bb4628d1bbb79b98c98fcb366ee2dec997134192983bba4f727451d78ce54b4906aaf061e392b5f7be73468addb9a63be465f0de9c44786c62b4f0c3c6d9b4a7519ec08c4756831c93cbcc7d3305711886f9a1846ba64769bcd00537128bc63ca40ec2fd7696eacb19e8c6b19340001cf3422f3f38accb95b805ebb1676a630fb6be1b071380873497450157aaace5c0f13bc606ab1c90552b27cc9a8cefbbf751d4b8c6f0db86dfc7a4bc3495dcb86c45d6709e9219a79f3fa7f1a23f078c3bf47c29a9686cd213665b8f4abd4070ee0df8cbb8893254d30dc0fb86987e0aa333fe5f8fac5d92d10cf78d436a4e8e054d966e22197cb68bab51f64da20afb74798fdba718e0190b46e9565c4a1b6d0ae8cc8d009a6df1579dd125c1e17199aaaed6841864c33f9ea66ac523d9e34e5174c0753ea9b0084ddbc6b17de711a6daf9d04963ca7ebccadd1c060e4a87c08a4f983751f803d15e4ca7bd2f4d3af2ecdfba8d6f539de6f6ec17af92223c12e055888a645d1eb20d6be180a8910c0cdbd04e793b7dd458bb784262aa4899454972c8f8681acdfa0a10f2c52ff0679add8faf61473caf2f89fecbc3cc321886b9d32bc318a313654dee2474d347e7085a5827b1307d9e780afe421286ebbc8522a82756404c65d05b0102834fe89f8cc223bcbc7e22076d8f657c93772af94973ee0ac1a2c3d4d41466502787299dbd5c1a9e7fbde69457defde15433b2770cd0edad9e4bf8c89a789497c6ad2360507a26660abd692c3d43cb979520974528c51fac70b07e347e5e26bc001a0667f287ef7aadb61e9a5646325f1b822dc84cfde932139379ce85ffeaadc39bfa07941807543aac70a5efb8e8a3222b549ea142dd3a9b60991a1514f58276cd53e">>
        ],
      <<"withdrawals">> => [
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0xb49">>,
           <<"index">> => <<"0x29011">>,
           <<"validatorIndex">> => <<"0x1a1">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0xb49">>,
           <<"index">> => <<"0x29012">>,
           <<"validatorIndex">> => <<"0x1a7">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0xb49">>,
           <<"index">> => <<"0x29013">>,
           <<"validatorIndex">> => <<"0x1a8">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0xb49">>,
           <<"index">> => <<"0x29014">>,
           <<"validatorIndex">> => <<"0x1a9">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x29015">>,
           <<"validatorIndex">> => <<"0x1ac">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x29016">>,
           <<"validatorIndex">> => <<"0x1af">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x29017">>,
           <<"validatorIndex">> => <<"0x1b0">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x29018">>,
           <<"validatorIndex">> => <<"0x1b1">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x29019">>,
           <<"validatorIndex">> => <<"0x1b3">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x2901a">>,
           <<"validatorIndex">> => <<"0x1b4">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x2901b">>,
           <<"validatorIndex">> => <<"0x1b8">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x2901c">>,
           <<"validatorIndex">> => <<"0x1bc">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x2901d">>,
           <<"validatorIndex">> => <<"0x1bd">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x2901e">>,
           <<"validatorIndex">> => <<"0x1c1">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x2901f">>,
           <<"validatorIndex">> => <<"0x1c4">>
          },
         #{
           <<"address">> => <<"0x25c4a76e7d118705e7ea2e9b7d8c59930d8acd3b">>,
           <<"amount">> => <<"0x786">>,
           <<"index">> => <<"0x29020">>,
           <<"validatorIndex">> => <<"0x1c6">>
          }
        ]
      }
    }.

cancun() ->
    #{
      number => 6985356,
      block_hash => <<"0xe02fe9c09c65a757fc09f650fb42db0f0d18430edd8e6f2f76e8dde08e47e9b2">>,
      transactions_root => <<"0x1b03d4d9a9d07c94f76fc91deb355be7e5e991c06ec1275781e7edc7e686bbc1">>,
      withdrawals_root => <<"0x2e4e007c37d52586849862a98d865b971fd5c981edc0263d93be119b75acbc89">>,
      payload => #{
      <<"baseFeePerGas">> => <<"0xc0ba4af9">>,
      <<"blobGasUsed">> => <<"0x0">>,
      <<"blockHash">> => <<"0xe02fe9c09c65a757fc09f650fb42db0f0d18430edd8e6f2f76e8dde08e47e9b2">>,
      <<"blockNumber">> => <<"0x6a968c">>,
      <<"excessBlobGas">> => <<"0x0">>,
      <<"extraData">> => <<"0xd883010e07846765746888676f312e32322e35856c696e7578">>,
      <<"feeRecipient">> => <<"0x9b984d5a03980d8dc0a24506c968465424c81dbe">>,
      <<"gasLimit">> => <<"0x1c9c380">>,
      <<"gasUsed">> => <<"0xe68171">>,
      <<"logsBloom">> => <<"0x2400001440044000081002020200222044008000000200800080088220000000008000400000001000002001008400810050000240300c000242100c04040140000080000404000240000002100006000401000001040000500040800000100200004410020010010028000020081802000808c400400000000000208000004002120000000020000000000400400040000104000000820000010000408000402000000000004020080021001c0480000102402802000000008000860000000000000020000400000010002008160a00404000000400804001224000000060040000000040080000000000102004000000080000188000000000448000000100">>,
      <<"parentBeaconBlockRoot">> => <<"0x0c1813ffc906ce6c76af49c7936a9f94b0fd8a959a1e2b666aa75ed6aaa1582e">>,
      <<"parentHash">> => <<"0xb0449ef6b612ee7ddfc25c25651df3c169069eb1edcfb77d0113a9675853c851">>,
      <<"prevRandao">> => <<"0x84ccc1f0c9ec9b27a896591f3b3ef9248b38214f730a098bdf8cb0e0fd96ba0b">>,
      <<"receiptsRoot">> => <<"0xe20282b479f5e2f18032a6c9c2aea03461f3339b94e266f6a397e754f0f7ad6c">>,
      <<"stateRoot">> => <<"0xc997228a82fdbc1008d685d55b676e5cff482c784348f79a110f7e3afdd00b86">>,
      <<"timestamp">> => <<"0x6723db90">>,
      <<"transactions">> => [
         <<"0x02f9041683aa36a744844190ab0085027764d16a8401c9c38094f564eea7960ea244bfebcbbb17858748606147bf80b903a4613e827b0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000fc1ded8c5a8f508f7ec114c32afb70c75793f03c000000000000000000000000fc1ded8c5a8f508f7ec114c32afb70c75793f03c00000000000000000000000081655c54497cc65293d1d349c54f5959585ed6eb000000000000000000000000049799edf880c257f7bbe53390c4b873ad817790000000000000000000000000747b82621644e4dd4fa87e5501232390577dddae0000000000000000000000009e1cb0d03d69382f640d665ceba7c16d487d220a000000000000000000000000000000000000000000000000000000000000055800000000000000000000000000000000000000000000000000000000000c3c9d00000000000000000000000000000000000000000000000000000000015bb71b0000000000000000000000000000000000000000000000000000000000000240000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000039387000000000000000000000000000000000000000000000000000000000000000001038512e02c4c3f7bdaec27d00edf55b7155e0905301e1a88083e4e0a6764d54c0000000000000000000000000000000000000000000000000000000000000049000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000002a300000000000000000000000000000000000000000000000000000000000049d4000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001dead00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000042307830343364356332336164326361396562636234373362636539633839653463393737383831646231653664386537343064653836313432346130333430393033000000000000000000000000000000000000000000000000000000000000c080a012c9c9599d9e7db045bdc41bacba8b6d812fd017ae9217b3061f0f95db2e4006a0658045d461237b897024a3e4390dc3231568da72dd873936914ccc06cdc7d085">>,
         <<"0xf9011681e784c707a5698306cc41945f5a404a5edabcdd80db05e8e54a78c9ebf000c288016345785d8a0000b8a4e11013dd000000000000000000000000a0a230b50f1d700a91825b306796b3d6c9d50b7a0000000000000000000000000000000000000000000000000000000000030d400000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000b73757065726272696467650000000000000000000000000000000000000000008401546d71a0a00777e27029b8d7cc43b5a47a17f2dc62a18d1c71d08a82ee688afb4e7b1b74a007547c5ab1a5bddeede53d7dfe921e489aa15253fd53c682046115c59e04df7c">>,
         <<"0x02f9011a83aa36a7058402f51c8d84c54a6de1837c9f8a94ea58fca6849d79ead1f26608855c2d6407d54ce2880404ddaa66f40000b8a4e11013dd0000000000000000000000003aa08cb1d5769b19f5923722e89622e55b269e5c0000000000000000000000000000000000000000000000000000000000030d400000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000b7375706572627269646765000000000000000000000000000000000000000000c001a0e43d334d4b795f9c7fa5a057f576ec3023a9f83ee3fb19f4b2e00e4f9e307a7e9f4e2549ba1cb31388807b9ee899800a015f7f845aea0269e031321c912920eb">>
        ],
      <<"withdrawals">> => [
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x34fb0">>,
           <<"index">> => <<"0x3cf13a9">>,
           <<"validatorIndex">> => <<"0x3a9">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x34fb0">>,
           <<"index">> => <<"0x3cf13aa">>,
           <<"validatorIndex">> => <<"0x3aa">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13ab">>,
           <<"validatorIndex">> => <<"0x3ab">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13ac">>,
           <<"validatorIndex">> => <<"0x3ac">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13ad">>,
           <<"validatorIndex">> => <<"0x3ad">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13ae">>,
           <<"validatorIndex">> => <<"0x3ae">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x34fb0">>,
           <<"index">> => <<"0x3cf13af">>,
           <<"validatorIndex">> => <<"0x3af">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b0">>,
           <<"validatorIndex">> => <<"0x3b0">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b1">>,
           <<"validatorIndex">> => <<"0x3b1">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b2">>,
           <<"validatorIndex">> => <<"0x3b2">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b3">>,
           <<"validatorIndex">> => <<"0x3b3">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b4">>,
           <<"validatorIndex">> => <<"0x3b4">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b5">>,
           <<"validatorIndex">> => <<"0x3b5">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x34fb0">>,
           <<"index">> => <<"0x3cf13b6">>,
           <<"validatorIndex">> => <<"0x3b6">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b7">>,
           <<"validatorIndex">> => <<"0x3b7">>
          },
         #{
           <<"address">> => <<"0xe276bc378a527a8792b353cdca5b5e53263dfb9e">>,
           <<"amount">> => <<"0x33a26">>,
           <<"index">> => <<"0x3cf13b8">>,
           <<"validatorIndex">> => <<"0x3b8">>
          }
        ]
      }
    }.
