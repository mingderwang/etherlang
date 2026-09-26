-module(eth_bloom).

%% 2048-bit Ethereum logs bloom: keccak of each item sets 3 bits.
%% Bit i lives in byte 255-i/8 at mask 1<<(i rem 8) (bits counted from the
%% end, matching go-ethereum's types.Bloom).

-export([new/0, add/2, add_logs/2, contains/2]).

new() -> binary:copy(<<0>>, 256).

add(Bloom, Item) when byte_size(Bloom) =:= 256, is_binary(Item) ->
    H = eth_keccak:hash(Item),
    <<B0:16, B1:16, B2:16, _/binary>> = H,
    set_bit(set_bit(set_bit(Bloom, B0 band 2047), B1 band 2047), B2 band 2047).

%% add_logs/2 accepts the two shapes a log arrives in. Execution produces
%% {Address, Topics, Data} tuples, while logs read back from a peer or a
%% JSON-RPC query are maps with atom or binary keys. Handling only the map shape
%% meant maps:get/3 hit a tuple and raised badmap, so finalizing any block
%% containing a log-emitting transaction failed while computing its own bloom --
%% and the same path working for a log-free block gave no hint why it stopped.
add_logs(Bloom, Logs) ->
    lists:foldl(fun(Log, Acc) ->
        {Address, Topics} = log_identity(Log),
        lists:foldl(fun(T, A) -> add(A, T) end, add(Acc, Address), Topics)
    end, Bloom, Logs).

log_identity({Address, Topics, _Data}) ->
    {Address, Topics};
log_identity(Log) when is_map(Log) ->
    {maps:get(address, Log, maps:get(<<"address">>, Log, <<>>)),
     maps:get(topics, Log, maps:get(<<"topics">>, Log, []))}.

contains(Bloom, Item) when byte_size(Bloom) =:= 256, is_binary(Item) ->
    H = eth_keccak:hash(Item),
    <<B0:16, B1:16, B2:16, _/binary>> = H,
    has_bit(Bloom, B0 band 2047) andalso
    has_bit(Bloom, B1 band 2047) andalso
    has_bit(Bloom, B2 band 2047).

set_bit(Bloom, Bit) ->
    Pos = 255 - Bit div 8,
    <<Pre:Pos/binary, Byte, Post/binary>> = Bloom,
    <<Pre/binary, (Byte bor (1 bsl (Bit rem 8))), Post/binary>>.

has_bit(Bloom, Bit) ->
    Pos = 255 - Bit div 8,
    <<_:Pos/binary, Byte, _/binary>> = Bloom,
    (Byte band (1 bsl (Bit rem 8))) =/= 0.
