-module(eth_forkid).

%% EIP-2124 ForkID for Sepolia: schedule, hash computation, and remote
%% validation following go-ethereum's core/forkid ruleset (rules 1, 1a, 1b,
%% 2, 3, 4) including the timestamp-threshold NEXT comparison.
%%
%% Schedule source: params.SepoliaChainConfig in go-ethereum (block forks
%% with number 0 and times at or before genesis are excluded, matching
%% gatherForks).

-export([schedule/1, genesis/1, genesis_time/1]).
-export([current/4, validate/6]).

%% Sepolia genesis (params.SepoliaGenesisHash).
-define(GENESIS, <<16#25, 16#a5, 16#cc, 16#10, 16#6e, 16#ea, 16#71, 16#38,
                   16#ac, 16#ab, 16#33, 16#23, 16#1d, 16#71, 16#60, 16#d6,
                   16#9c, 16#b7, 16#77, 16#ee, 16#0c, 16#2c, 16#55, 16#3f,
                   16#cd, 16#df, 16#51, 16#38, 16#99, 16#3e, 16#6d, 16#d9>>).
%% Sepolia genesis timestamp (block 0).
-define(GENESIS_TIME, 1655733600).
%% Mainnet genesis timestamp: splits NEXT block-vs-time comparisons.
-define(TIME_THRESHOLD, 1438269973).

genesis(sepolia) -> ?GENESIS;
genesis(mainnet) ->
    binary:decode_hex(<<"d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3">>).

genesis_time(sepolia) -> ?GENESIS_TIME;
genesis_time(mainnet) -> ?TIME_THRESHOLD.

%% {BlockForks, TimeForks}, ascending, deduplicated, genesis-covered
%% entries removed.
schedule(sepolia) ->
    Blocks = lists:usort([1735371]),
    Times = lists:usort([1677557088, 1706655072, 1741159776, 1760427360,
                         1761017184, 1761607008, 1791294816]),
    {Blocks, [T || T <- Times, T > ?GENESIS_TIME]};
schedule(mainnet) ->
    Blocks = lists:usort([1150000, 1920000, 2463000, 2675000, 4370000,
                          7280000, 9069000, 9200000, 12244000, 12965000,
                          13773000, 15050000]),
    Times = lists:usort([1681338455, 1710338135, 1746612311, 1764798551,
                         1765290071, 1767747671]),
    {Blocks, Times}.

%% Current ForkID for head block number + timestamp.
%% Returns {Hash4, Next} with Next=0 when no fork is known ahead.
current(Genesis, {Blocks, Times}, HeadNum, HeadTime) ->
    H0 = erlang:crc32(Genesis),
    case pass_blocks(Blocks, HeadNum, H0) of
        {next, H, Next} ->
            {hash4(H), Next};
        {done, H} ->
            case pass_times(Times, HeadTime, H) of
                {next, H1, Next} -> {hash4(H1), Next};
                {done, H1} -> {hash4(H1), 0}
            end
    end.

%% Validate a remote {Hash4, Next} against our head. Mirrors geth:
%% same-hash (rules 1/1a/1b), past-subset (rule 2), future-superset
%% (rule 3), else reject (rule 4).
validate(Genesis, Sched, HeadNum, HeadTime, RemoteHash, RemoteNext) ->
    {Blocks, Times} = Sched,
    Forks = Blocks ++ Times,
    Sums = sums(Genesis, Forks),
    NB = length(Blocks),
    I = first_unpassed(Forks, NB, HeadNum, HeadTime),
    case lists:nth(I + 1, Sums) =:= RemoteHash of
        true ->
            {Head, Time} = head_for(NB, I, HeadNum, HeadTime),
            AnnouncedPassed = RemoteNext > 0 andalso
                (Head >= RemoteNext orelse
                 (RemoteNext > ?TIME_THRESHOLD andalso Time >= RemoteNext)),
            case AnnouncedPassed of
                true -> {error, local_incompatible};
                false -> ok
            end;
        false ->
            case find_index(RemoteHash, lists:sublist(Sums, I), 0) of
                {ok, J} ->
                    case lists:nth(J + 1, Forks) =:= RemoteNext of
                        true -> ok;
                        false -> {error, remote_stale}
                    end;
                error ->
                    case lists:member(RemoteHash, lists:nthtail(I + 1, Sums)) of
                        true -> ok;
                        false -> {error, local_incompatible}
                    end
            end
    end.

%% ---------------------------------------------------------------------------

first_unpassed(Forks, NB, HeadNum, HeadTime) ->
    fu(Forks, NB, HeadNum, HeadTime, 0).

fu([], _, _, _, I) -> I;
fu([F | Rest], NB, HeadNum, HeadTime, I) ->
    Head = case I < NB of
               true -> HeadNum;
               false -> HeadTime
           end,
    case Head >= F of
        true -> fu(Rest, NB, HeadNum, HeadTime, I + 1);
        false -> I
    end.

head_for(NB, I, HeadNum, HeadTime) ->
    case I < NB of
        true -> {HeadNum, HeadTime};
        false -> {HeadTime, HeadTime}
    end.

pass_blocks([], _Head, H) -> {done, H};
pass_blocks([F | Rest], Head, H) when F =< Head ->
    pass_blocks(Rest, Head, update(H, F));
pass_blocks([F | _], _Head, H) ->
    {next, H, F}.

pass_times([], _Time, H) -> {done, H};
pass_times([F | Rest], Time, H) when F =< Time ->
    pass_times(Rest, Time, update(H, F));
pass_times([F | _], _Time, H) ->
    {next, H, F}.

update(Hash, Fork) -> erlang:crc32(Hash, <<Fork:64/big>>).
hash4(H) -> <<H:32/big>>.

%% All prefix sums: sums[0] = genesis-only, sums[i] covers forks[0..i-1].
sums(Genesis, Forks) ->
    G = erlang:crc32(Genesis),
    {Sums, _} = lists:foldl(fun(F, {Acc, H}) ->
        H1 = update(H, F),
        {[hash4(H1) | Acc], H1}
    end, {[hash4(G)], G}, Forks),
    lists:reverse(Sums).

find_index(_V, [], _I) -> error;
find_index(V, [V | _], I) -> {ok, I};
find_index(V, [_ | Rest], I) -> find_index(V, Rest, I + 1).
