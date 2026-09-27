-module(eth_test_util).

-export([start_apps/0, free_port/0, with_port/1, tmp_dir/1, tmp_dir/0,
         bin_to_hex/1, wait_until/3, block/3, header/3, header_hash/3,
         make_blocks/4,
         %% The execution context. This was private to eth_finalize_tests, and
         %% it is the only infrastructure that makes eth_block:finalize/1
         %% actually execute -- so a second test module that needs a real verdict
         %% out of finalize/1 had no way to get one and resorted to writing the
         %% verdict term by hand. See finalize_ctx/1.
         finalize_ctx/1, store_parent/1, seed_account/0, inbound_block/2,
         seed_root_with_parent/1]).

start_apps() ->
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(cowboy),
    ok.

free_port() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    ok = gen_tcp:close(L),
    Port.

%% free_port/0 cannot be made safe on its own. It listens on port 0, reads
%% back the number the OS chose, and closes the socket -- so between the close
%% and the caller's own bind the number is unowned, and anything else in the VM
%% can take it. A full suite binds dozens of listeners, and one collision showed
%% up as `eaddrinuse` killing eth_sync_tests_peer's discv4 start, which EUnit
%% reports as a *cancelled* test with no failure and no assertion: a port race
%% that looks like the runner gave up.
%%
%% The port has to be a number, because discv4 and the peer listener both
%% advertise it in an enode URL, so the socket cannot simply be held open across
%% the handover. This closes the gap by retrying: draw a fresh port, let the
%% caller bind, and on eaddrinuse draw another. The caller's Fun gets the port
%% and must pass it through to the module under test.
with_port(Fun) ->
    with_port(Fun, 5).

with_port(Fun, 0) ->
    error({port_exhausted, Fun});
with_port(Fun, Attempts) ->
    Port = free_port(),
    try Fun(Port) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            case is_address_in_use(Class, Reason) of
                true ->
                    %% Let the loser finish failing before we take a new port,
                    %% and let the kernel drop whatever it is holding.
                    timer:sleep(20),
                    with_port(Fun, Attempts - 1);
                false ->
                    erlang:raise(Class, Reason, Stack)
            end
    end.

%% A lost bind arrives here as a *badmatch*, not as a bare `eaddrinuse`, and
%% that is the whole reason the retry is worth having at all.
%%
%% gen_tcp:listen/2 and gen_udp:open/2 do not raise: they return
%% `{error, eaddrinuse}'. The gen_servers that wrap them (eth_discv4, eth_peer,
%% eth_rpc_server) return `{stop, eaddrinuse}` from init, which
%% gen_server:start_link/3 reports as `{error, eaddrinuse}'. Every caller in
%% this suite then writes `{ok, _} = Mod:start_link(...)`, so the term that
%% actually arrives at the catch above is
%%
%%     error:{badmatch, {error, eaddrinuse}}
%%
%% A matcher written for the bare `eaddrinuse` does not recognise that, so the
%% first collision re-raised and the retry never ran -- a test that looked
%% flaky, was a dead retry loop, and was reported as a cancelled test with no
%% assertion. The bare and twice-wrapped forms below are not produced by any
%% caller in this suite; they are kept because a caller that propagates the
%% error tuple instead of matching it would otherwise turn a lost bind into a
%% five-attempt stall and then a confusing non-port failure.
is_address_in_use(error, eaddrinuse) -> true;
is_address_in_use(error, {error, eaddrinuse}) -> true;
is_address_in_use(error, {error, {error, eaddrinuse}}) -> true;
is_address_in_use(error, {badmatch, {error, eaddrinuse}}) -> true;
is_address_in_use(_, _) -> false.

tmp_dir() -> tmp_dir(erlang:unique_integer([positive])).

tmp_dir(Prefix) ->
    %% NOTE: erlang:unique_integer/1 restarts from the same base in every
    %% fresh VM, so directories derived from it alone COLLIDE across test
    %% runs (stale DETS state leaked from run to run, causing phantom
    %% missing_parent/reorg failures). The OS pid makes each VM's
    %% directories unique.
    PidPart = os:getpid(),
    D = filename:join("/tmp", "etherlang_test_" ++ integer_to_list(Prefix)
                           ++ "_" ++ PidPart
                           ++ "_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(D, "x")),
    D.

bin_to_hex(Bin) ->
    << <<(hex_digit(H)), (hex_digit(L))>> || <<H:4, L:4>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

wait_until(Fun, SleepMs, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_until_n(Fun, SleepMs, Deadline).

wait_until_n(Fun, SleepMs, Deadline) ->
    case try Fun() catch _:_ -> false end of
        true ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> error(wait_timeout);
                false ->
                    timer:sleep(SleepMs),
                    wait_until_n(Fun, SleepMs, Deadline)
            end
    end.

%% ---------------------------------------------------------------------------
%% Deterministic synthetic blocks (used by the mock node and chain tests).
%% Blocks carry *real* RLP+keccak header hashes so the chain store's
%% verification path is exercised.
%% ---------------------------------------------------------------------------

-define(ZERO32, <<"0x0000000000000000000000000000000000000000000000000000000000000000">>).
-define(EMPTY_UNCLE_HASH, <<"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347">>).

tx_hash(Num, Idx) ->
    Hash = crypto:hash(sha256, term_to_binary({tx, Num, Idx})),
    <<"0x", (bin_to_hex(Hash))/binary>>.

%% Header-only map for block Num chained to Parent. `Salt' goes into extraData
%% so that competing forks from the same parent hash differently.
header(Num, Parent, Salt) ->
    #{<<"parentHash">> => Parent,
      <<"sha3Uncles">> => ?EMPTY_UNCLE_HASH,
      <<"miner">> => <<"0x0000000000000000000000000000000000000000">>,
      <<"stateRoot">> => ?ZERO32,
      <<"transactionsRoot">> => ?ZERO32,
      <<"receiptsRoot">> => ?ZERO32,
      <<"logsBloom">> => <<"0x">>,
      <<"difficulty">> => eth_hex:encode_int(0),
      <<"number">> => eth_hex:encode_int(Num),
      <<"gasLimit">> => eth_hex:encode_int(30000000),
      <<"gasUsed">> => eth_hex:encode_int(0),
      <<"timestamp">> => eth_hex:encode_int(1000 + Num),
      <<"extraData">> => eth_hex:encode_int(Salt),
      <<"mixHash">> => ?ZERO32,
      <<"nonce">> => <<"0x0000000000000000">>}.

header_hash(Num, Parent, Salt) ->
    {ok, H} = eth_header:hash(header(Num, Parent, Salt)),
    <<"0x", (bin_to_hex(H))/binary>>.

block(Num, Parent, Salt) ->
    H = header_hash(Num, Parent, Salt),
    (header(Num, Parent, Salt))#{
      <<"hash">> => H,
      <<"totalDifficulty">> => eth_hex:encode_int(0),
      <<"size">> => eth_hex:encode_int(600),
      <<"transactions">> =>
          [#{<<"hash">> => tx_hash(Num, 0),
             <<"blockHash">> => H,
             <<"blockNumber">> => eth_hex:encode_int(Num),
             <<"from">> => <<"0x1000000000000000000000000000000000000001">>,
             <<"to">> => <<"0x1000000000000000000000000000000000000002">>,
             <<"gas">> => eth_hex:encode_int(21000),
             <<"gasPrice">> => eth_hex:encode_int(1),
             <<"input">> => <<"0x">>,
             <<"nonce">> => eth_hex:encode_int(0),
             <<"transactionIndex">> => eth_hex:encode_int(0),
             <<"value">> => eth_hex:encode_int(0),
             <<"v">> => <<"0x1">>,
             <<"r">> => <<"0x0">>,
             <<"s">> => <<"0x0">>},
           #{<<"hash">> => tx_hash(Num, 1),
             <<"blockHash">> => H,
             <<"blockNumber">> => eth_hex:encode_int(Num),
             <<"from">> => <<"0x1000000000000000000000000000000000000001">>,
             <<"to">> => <<"0x1000000000000000000000000000000000000003">>,
             <<"gas">> => eth_hex:encode_int(21000),
             <<"gasPrice">> => eth_hex:encode_int(1),
             <<"input">> => <<"0x">>,
             <<"nonce">> => eth_hex:encode_int(1),
             <<"transactionIndex">> => eth_hex:encode_int(1),
             <<"value">> => eth_hex:encode_int(0),
             <<"v">> => <<"0x1">>,
             <<"r">> => <<"0x0">>,
             <<"s">> => <<"0x0">>}],
      <<"uncles">> => []}.

%% Build Count blocks starting at From, chained to Parent, salted with Salt
%% so different forks sharing a {Num, Parent} produce different hashes.
make_blocks(From, Count, Parent, Salt) ->
    lists:foldl(
        fun(Num, {P, Blocks}) ->
            B = block(Num, P, Salt),
            {maps:get(<<"hash">>, B), Blocks ++ [B]}
        end, {Parent, []}, lists:seq(From, From + Count - 1)).

%% ---------------------------------------------------------------------------
%% The execution context
%% ---------------------------------------------------------------------------
%%
%% eth_block:finalize/1 only executes -- and only produces a real Verification map
%% -- when the parent block is in the chain store and the MPT is switched to be
%% the state source. Both are global: eth_mpt is a registered singleton and
%% eth_state:base_source/0 is a process-wide application env. A leaked change
%% redirects another module's reads for the rest of the run, which is how a
%% passing suite starts failing somewhere else.
%%
%% This was private to eth_finalize_tests, which is a problem beyond tidiness: a
%% test that wanted a genuine verdict out of finalize/1 had no way to obtain one,
%% so it wrote the verdict by hand -- in the shape the module under test expected
%% to see. Such a test cannot fail, because it agrees with the code under test by
%% construction. That is how eth_engine's verdict mapping came to be tested
%% against a 4-tuple `{mismatch, Which, Declared, Computed}' for all three roots,
%% while eth_block produces a 3-tuple for the state root: the test passed and the
%% engine answered SYNCING for a wrong state root. Fixtures must come from the
%% code's real output, not from a guess at it.

%% Run Fun against a fresh MPT and chain store, leaving the process-wide
%% base-source setting as it was found.
finalize_ctx(Fun) ->
    _ = ensure_started(eth_mpt),
    ok = eth_mpt:clear(),
    _ = ensure_started(eth_chain, tmp_dir()),
    Previous = eth_state:base_source(),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous),
        _ = clear_mpt(),
        _ = stop_chain()
    end.

%% start_link/1 links to the calling process, and a process that is already
%% registered is not an error here -- another test module in the same VM may have
%% started it and left it up.
ensure_started(Mod) ->
    case whereis(Mod) of
        undefined -> {ok, Pid} = Mod:start_link(), Pid;
        Pid -> Pid
    end.

ensure_started(eth_chain, Dir) ->
    case whereis(eth_chain) of
        undefined -> {ok, Pid} = eth_chain:start_link(eth_chain, Dir), Pid;
        Pid -> Pid
    end.

clear_mpt() ->
    try eth_mpt:clear() catch _:_ -> ok end.

stop_chain() ->
    try gen_server:stop(eth_chain) catch _:_ -> ok end.

%% The empty-account code hash, i.e. Keccak256(<<>>). Spelled out rather than
%% computed so a test's account does not depend on eth_keccak being right.
-define(EMPTY_CODE_HASH, <<16#c5, 16#d2, 16#46, 16#01, 16#86, 16#f7, 16#23,
                          16#3c, 16#92, 16#7e, 16#7d, 16#b2, 16#dc, 16#c7,
                          16#03, 16#c0, 16#e5, 16#00, 16#b6, 16#53, 16#ca,
                          16#82, 16#27, 16#3b, 16#7b, 16#fa, 16#d8, 16#04,
                          16#5d, 16#85, 16#a4, 16#70>>).

%% Put one funded account in the (already cleared) MPT and return the resulting
%% state root, which is what a parent block must declare for the node to be
%% entitled to check anything about the block that names it.
seed_account() ->
    ok = eth_mpt:put_account(<<16#aa:160>>, 1000, 7, ?EMPTY_CODE_HASH),
    eth_mpt:state_root().

%% The common case in one call: seed the trie, store a parent declaring that root,
%% and hand back the parent's hash. A block that names it as its parent will then
%% be executed against state this node actually holds, which is the only
%% configuration in which finalize/1 returns `{verified, _}'.
seed_root_with_parent(_) ->
    Parent = store_parent(seed_account()),
    {Parent, eth_mpt:state_root()}.

%% Store a block declaring ParentRoot as its state root and return its hash, so a
%% child block can name it as a parent. The header is built with header/3 because
%% the chain store recomputes and verifies the hash on append, so the state root
%% has to be substituted before the hash is taken.
store_parent(ParentRoot) ->
    Base = header(0, <<"0x0000000000000000000000000000000000000000000000000000000000000000">>, 0),
    Block = Base#{
              <<"totalDifficulty">> => eth_hex:encode_int(0),
              <<"size">> => eth_hex:encode_int(600),
              <<"stateRoot">> => bin_to_hex0x(ParentRoot)
             },
    {ok, HashHex} = eth_header:verify(Block),
    ok = eth_chain:append([{0, Block#{<<"hash">> => HashHex}, true}]),
    hex_to_bin(HashHex).

%% An inbound block, built the way a peer's arrives: from_json/1 over a JSON-RPC
%% header map. Constructing one through the record instead would bypass exactly
%% the path where a peer's declared roots get read, which is the path under test.
inbound_block(ParentHash, Overrides) ->
    Base = #{<<"parentHash">> => ParentHash,
             <<"number">> => <<"0x1">>,
             <<"timestamp">> => <<"0x64">>,
             <<"gasLimit">> => <<"0x1c9c380">>,
             <<"baseFeePerGas">> => <<"0x3b9aca00">>},
    eth_block:from_json(maps:merge(Base, Overrides)).

%% Lowercase, matching eth_header's canonical hash form: the chain store indexes
%% by it, so an uppercase key would silently miss.
bin_to_hex0x(Bin) -> <<"0x", (string:lowercase(bin_to_hex(Bin)))/binary>>.

hex_to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest).