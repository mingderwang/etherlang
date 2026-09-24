-module(eth_forkid_tests).

-include_lib("eunit/include/eunit.hrl").

%% EIP-2124 mainnet vectors (well-known chain history).
mainnet_vectors_test() ->
    Gen = eth_forkid:genesis(mainnet),
    Sched = eth_forkid:schedule(mainnet),
    Cases = [{0, 0, "fc64ec04", 1150000},
             {1150000, 0, "97c2c34c", 1920000},
             {1920000, 0, "91d1f948", 2463000},
             {2463000, 0, "7a64da13", 2675000},
             {2675000, 0, "3edd5b10", 4370000},
             {4370000, 0, "a00bc324", 7280000},
             {7280000, 0, "668db0af", 9069000},
             {9069000, 0, "879d6e30", 9200000},
             {9200000, 0, "e029e991", 12244000},
             {12244000, 0, "0eb440f6", 12965000},
             {12965000, 0, "b715077d", 13773000},
             {13773000, 0, "20c327fc", 15050000},
             {15050000, 0, "f0afd0e3", 1681338455},
             {15500000, 1681338455, "dce96c2d", 1710338135},
             {16000000, 1710338135, "9f3d2254", 1746612311},
             {16000000, 1746612311, "c376cf8b", 1764798551},
             {16000000, 1764798551, "5167e2a6", 1765290071},
             {16000000, 1765290071, "cba2a1c0", 1767747671},
             {16000000, 1767747671, "07c9462e", 0}],
    lists:foreach(fun({Num, Time, Hash, Next}) ->
        ?assertEqual({binary:decode_hex(list_to_binary(Hash)), Next},
                     eth_forkid:current(Gen, Sched, Num, Time))
    end, Cases).

%% Validation ruleset: ported geth cases (legacy subset + time cases).
validate_test() ->
    Gen = eth_forkid:genesis(mainnet),
    Sched = eth_forkid:schedule(mainnet),
    Head = 4370000,
    Time = 0,
    %% Same hash, no future announced: accept (rule 1b).
    ?assertEqual(ok, eth_forkid:validate(Gen, Sched, Head, Time,
                                         hex("a00bc324"), 7280000)),
    %% Same hash but remote NEXT already passed locally: reject (rule 1a).
    ?assertEqual({error, local_incompatible},
                 eth_forkid:validate(Gen, Sched, 8000000, Time,
                                     hex("668db0af"), 7280000)),
    %% Stale remote (Petersburg hash) with correct NEXT: accept (rule 2).
    ?assertEqual(ok, eth_forkid:validate(Gen, Sched, Head, Time,
                                         hex("668db0af"), 7280000)),
    %% Stale remote with wrong NEXT: reject (rule 2).
    ?assertEqual({error, remote_stale},
                 eth_forkid:validate(Gen, Sched, Head, Time,
                                     hex("3edd5b10"), 9999999)),
    %% Future superset ignores NEXT (rule 3): Petersburg while we are at
    %% Byzantium accepts even with a later NEXT.
    ?assertEqual(ok, eth_forkid:validate(Gen, Sched, Head, Time,
                                         hex("668db0af"), 9069000)),
    %% Future superset (Istanbul while we are at Byzantium): accept (rule 3).
    ?assertEqual(ok, eth_forkid:validate(Gen, Sched, Head, Time,
                                         hex("879d6e30"), 9200000)),
    %% Unknown hash: reject (rule 4).
    ?assertEqual({error, local_incompatible},
                 eth_forkid:validate(Gen, Sched, Head, Time,
                                     hex("deadbeef"), 0)),
    %% Ported geth time cases (Shanghai era and later).
    ?assertEqual(ok, eth_forkid:validate(Gen, Sched, 20000000, 1681338455,
                                         hex("dce96c2d"), 16#FFFFFFFFFFFFFFFF)),
    ?assertEqual({error, local_incompatible},
                 eth_forkid:validate(Gen, Sched, 20000000, 1681338455,
                                     hex("12345678"), 0)),
    ?assertEqual({error, remote_stale},
                 eth_forkid:validate(Gen, Sched, 21000000, 1710338135,
                                     hex("dce96c2d"), 0)),
    ?assertEqual(ok, eth_forkid:validate(Gen, Sched, 21000000, 1700000000,
                                         hex("9f3d2254"), 0)).

%% Sepolia schedule is deterministic and progresses with head/time
%% (hashes from geth's forkid test vectors).
sepolia_test() ->
    Gen = eth_forkid:genesis(sepolia),
    Sched = eth_forkid:schedule(sepolia),
    ?assertEqual({hex("fe3366e7"), 1735371},
                 eth_forkid:current(Gen, Sched, 0, 1655733600)),
    ?assertEqual({hex("b96cbd13"), 1677557088},
                 eth_forkid:current(Gen, Sched, 1735371, 1655733600)),
    ?assertEqual({hex("f7f9bc08"), 1706655072},
                 eth_forkid:current(Gen, Sched, 1735372, 1677557088)),
    ?assertEqual({hex("88cf81d9"), 1741159776},
                 eth_forkid:current(Gen, Sched, 1735372, 1706655072)),
    ?assertEqual({hex("ed88b5fd"), 1760427360},
                 eth_forkid:current(Gen, Sched, 1735372, 1741159776)),
    ?assertEqual({hex("e2ae4999"), 1761017184},
                 eth_forkid:current(Gen, Sched, 1735372, 1760427360)),
    ?assertEqual({hex("56078a1e"), 1761607008},
                 eth_forkid:current(Gen, Sched, 1735372, 1761017184)),
    ?assertEqual({hex("268956b6"), 1791294816},
                 eth_forkid:current(Gen, Sched, 1735372, 1761607008)),
    ?assertEqual({hex("6c1d9423"), 0},
                 eth_forkid:current(Gen, Sched, 1735372, 1791294816)),
    %% Self-validation accepts.
    {H2, N2} = eth_forkid:current(Gen, Sched, 2000000, 1677557088),
    ?assertEqual(ok, eth_forkid:validate(Gen, Sched, 2000000, 1677557088, H2, N2)).

hex(S) -> binary:decode_hex(list_to_binary(S)).
