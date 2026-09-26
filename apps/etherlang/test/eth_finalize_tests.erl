%% Block finalization: what it recomputes, and -- more importantly -- what it
%% refuses to claim.
%%
%% The state root is the commitment a finalizing client is most tempted to
%% assert and least entitled to. These tests pin the difference between "the
%% node computed this root" and "the node could not compute it, and says so".

-module(eth_finalize_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ADDR_A, <<16#aa:160>>).
-define(ADDR_B, <<16#bb:160>>).
-define(EMPTY_CODE_HASH, <<16#c5, 16#d2, 16#46, 16#01, 16#86, 16#f7, 16#23,
                          16#3c, 16#92, 16#7e, 16#7d, 16#b2, 16#dc, 16#c7,
                          16#03, 16#c0, 16#e5, 16#00, 16#b6, 16#53, 16#ca,
                          16#82, 16#27, 16#3b, 16#7b, 16#fa, 16#d8, 16#04,
                          16#5d, 16#85, 16#a4, 16#70>>).

finalize_test_() ->
    [{"rejects an unknown parent", fun rejects_unknown_parent/0},
     {"reports state that is not local", fun reports_state_not_local/0},
     {"never stamps a root it cannot justify",
      fun does_not_stamp_a_root_it_cannot_justify/0},
     {"verifies against a locally held parent state",
      fun verifies_against_local_parent_state/0},
     {"detects a state root mismatch", fun detects_state_root_mismatch/0},
     {"restores the base source", fun base_source_is_restored/0},
     {"refuses to commit a peer's view", fun commit_requires_mpt_base_source/0},
     {"commit writes the overlay to the MPT", fun commit_writes_overlay_to_mpt/0},
     {"commit deletes zeroed slots", fun commit_deletes_zeroed_slots/0},
     {"commit preserves unmentioned fields",
      fun commit_preserves_unmentioned_fields/0},
     {"carries declared commitments through from_json",
      fun from_json_carries_declared_commitments/0},
     %% The other two commitments are verifiable too, and were not being checked.
     {"detects a receipts root mismatch", fun detects_receipts_root_mismatch/0},
     {"detects a transactions root mismatch",
      fun detects_transactions_root_mismatch/0},
     {"confirms a correct receipts root", fun confirms_correct_receipts_root/0},
     {"the transactions root needs no state", fun tx_root_needs_no_state/0},
     {"content roots are reported as verdicts",
      fun content_roots_are_verdicts/0}].

%% Each case gets a fresh MPT and a fresh chain store, and leaves the global
%% base-source setting as it found it: it is process-wide, so a leaked change
%% would silently redirect another module's reads.
with_ctx(Fun) ->
    ensure_started(eth_mpt),
    ok = eth_mpt:clear(),
    ensure_started(eth_chain, eth_test_util:tmp_dir()),
    Previous = eth_state:base_source(),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous),
        _ = clear_mpt(),
        _ = stop_chain()
    end.

%% start_link/1 links to the calling process, and a process that is already
%% registered is not an error here -- another test module in the same VM may
%% have started it and left it up.
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

%% ---------------------------------------------------------------------------
%% The parent is the anchor for execution
%% ---------------------------------------------------------------------------

%% A block whose parent the chain store has never seen cannot be executed
%% against anything. That has to be an error, not an execution against whatever
%% the store happens to contain.
rejects_unknown_parent() ->
    with_ctx(fun() ->
        Block = eth_block:new(<<"no such parent">>, 1),
        ?assertMatch({error, {unknown_parent, _}}, eth_block:finalize(Block))
    end).

%% ---------------------------------------------------------------------------
%% The state-root honesty gate
%% ---------------------------------------------------------------------------

%% With an empty MPT and a parent that declares some non-empty root, the local
%% store is provably not the parent's state. finalize/1 must say so rather than
%% compute a root over the empty trie and present it as the block's.
reports_state_not_local() ->
    with_ctx(fun() ->
        Parent = store_parent(<<16#11:256>>),
        {ok, Finalized, V} = eth_block:finalize(eth_block:new(Parent, 1)),
        ?assertEqual({unverified, state_not_local}, maps:get(state_root, V)),
        %% The empty trie's root is what a careless implementation would have
        %% stamped here. It must not appear.
        ?assertNotEqual(hex(eth_trie:root([])),
                        state_root_of(Finalized))
    end).

%% The decisive property, stated independently of which root the node happens to
%% compute: a node that holds no state reports {unverified, _}. The previous
%% implementation compared the block's declared root against eth_mpt's root and
%% returned ok, so a root computed over an unrelated store counted as verified.
does_not_stamp_a_root_it_cannot_justify() ->
    with_ctx(fun() ->
        Parent = store_parent(<<16#22:256>>),
        {ok, _, V} = eth_block:finalize(eth_block:new(Parent, 1)),
        ?assertMatch({unverified, _}, maps:get(state_root, V))
    end).

%% The positive case: seed the MPT so its own root *is* the parent's declared
%% state root. Only then is the node entitled to a verified verdict.
verifies_against_local_parent_state() ->
    with_ctx(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, ?EMPTY_CODE_HASH),
        ParentRoot = eth_mpt:state_root(),
        Parent = store_parent(ParentRoot),
        {ok, Finalized, V} = eth_block:finalize(eth_block:new(Parent, 1)),
        ?assertEqual({verified, ParentRoot}, maps:get(state_root, V)),
        ?assertEqual(ParentRoot, state_root_of(Finalized))
    end).

%% A block declaring a root other than the one execution produced is a mismatch,
%% not a pass. The block's own field is left at the parent's root, because
%% rewriting it to the computed value would erase the evidence.
detects_state_root_mismatch() ->
    with_ctx(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, ?EMPTY_CODE_HASH),
        ParentRoot = eth_mpt:state_root(),
        Parent = store_parent(ParentRoot),
        Lying = eth_block:declare_state_root(eth_block:new(Parent, 1),
                                             <<16#99:256>>),
        {ok, Finalized, V} = eth_block:finalize(Lying),
        ?assertMatch({unverified, {mismatch, <<16#99:256>>, ParentRoot}},
                     maps:get(state_root, V)),
        %% The root that was actually derived is the useful diagnostic. It is
        %% the parent's own root here because the block has no transactions.
        ?assertEqual(ParentRoot, state_root_of(Finalized))
    end).

%% Switching the base source is a process-wide setting. finalize/1 must restore
%% it, or a later eth_call would read from a store the caller never chose.
base_source_is_restored() ->
    with_ctx(fun() ->
        ok = eth_state:set_base_source(upstream),
        Parent = store_parent(<<16#33:256>>),
        _ = eth_block:finalize(eth_block:new(Parent, 1)),
        ?assertEqual(upstream, eth_state:base_source())
    end).

%% ---------------------------------------------------------------------------
%% Commit
%% ---------------------------------------------------------------------------

%% Committing an overlay that was only ever a view of a peer's chain would write
%% state this node does not own, under a root it cannot vouch for.
commit_requires_mpt_base_source() ->
    with_ctx(fun() ->
        ok = eth_state:set_base_source(upstream),
        State = eth_state:new(<<"0x1">>, #{}),
        ?assertEqual({error, not_committable},
                     eth_state:commit(eth_state:set_balance(State, ?ADDR_A, 42)))
    end).

commit_writes_overlay_to_mpt() ->
    with_ctx(fun() ->
        ok = eth_state:set_base_source(mpt),
        State = eth_state:new(<<"0x1">>, #{}),
        S1 = eth_state:set_balance(State, ?ADDR_A, 42),
        S2 = eth_state:set_nonce(S1, ?ADDR_A, 3),
        ?assertEqual(ok, eth_state:commit(S2)),
        #{balance := B, nonce := N} = eth_mpt:get_account(?ADDR_A),
        ?assertEqual(42, B),
        ?assertEqual(3, N),
        %% And the write is visible to a later read, which is the point of
        %% committing: the MPT has to reflect what execution produced.
        After = eth_state:new(<<"0x1">>, #{}),
        ?assertEqual(42, eth_state:balance(After, ?ADDR_A))
    end).

%% A slot written back to zero must not appear in the trie. Leaving a
%% zero-valued slot in place changes the storage root for no reason, and would
%% not match what another node computes from the same transactions.
commit_deletes_zeroed_slots() ->
    with_ctx(fun() ->
        ok = eth_state:set_base_source(mpt),
        S0 = eth_state:new(<<"0x1">>, #{}),
        S1 = eth_state:set_storage(S0, ?ADDR_A, 1, 16#1234),
        ok = eth_state:commit(S1),
        ?assertEqual(<<16#12, 16#34>>, eth_mpt:get_storage(?ADDR_A, <<1:256>>)),
        S2 = eth_state:set_storage(S1, ?ADDR_A, 1, 0),
        ok = eth_state:commit(S2),
        ?assertEqual(undefined, eth_mpt:get_storage(?ADDR_A, <<1:256>>))
    end).

%% A block that writes only a balance must not zero the account's nonce or code.
%% Those fields were never mentioned in the overlay, so committing them as zero
%% would silently destroy an account's code.
commit_preserves_unmentioned_fields() ->
    with_ctx(fun() ->
        ok = eth_state:set_base_source(mpt),
        Code = <<16#60, 16#00>>,
        Hash = eth_keccak:hash(Code),
        ok = eth_mpt:put_code(Hash, Code),
        ok = eth_mpt:put_account(?ADDR_A, 10, 9, Hash),
        S0 = eth_state:new(<<"0x1">>, #{}),
        ok = eth_state:commit(eth_state:set_balance(S0, ?ADDR_A, 11)),
        #{balance := B, nonce := N, codeHash := H} = eth_mpt:get_account(?ADDR_A),
        ?assertEqual(11, B),
        ?assertEqual(9, N),
        ?assertEqual(Hash, H),
        ?assertEqual(Code, eth_mpt:get_code(H))
    end).

%% ---------------------------------------------------------------------------
%% The content-derived commitments
%% ---------------------------------------------------------------------------

%% The receipts root is a Merkle root over the block's own receipts, so executing
%% the body produces it and a peer cannot choose it freely. Checking it means
%% comparing it against what the peer declared, which is what this now does.
%%
%% Reporting only the recomputed value -- the previous behaviour -- was not
%% verification: the number in the report was one this node had just computed,
%% under a key that read as though it had been confirmed, so a block declaring
%% any receipts root at all passed.
detects_receipts_root_mismatch() ->
    with_ctx(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, ?EMPTY_CODE_HASH),
        Parent = store_parent(eth_mpt:state_root()),
        Lying = inbound(Parent, #{<<"receiptsRoot">> => hex(<<16#77:256>>)}),
        {ok, _Finalized, V} = eth_block:finalize(Lying),
        ?assertMatch({unverified, {mismatch, receipts_root, <<16#77:256>>, _}},
                     maps:get(receipts_root, V))
    end).

%% The same for the transactions root, which is even easier to get wrong because
%% it depends on nothing but the block's own transaction list.
detects_transactions_root_mismatch() ->
    with_ctx(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, ?EMPTY_CODE_HASH),
        Parent = store_parent(eth_mpt:state_root()),
        Lying = inbound(Parent, #{<<"transactionsRoot">> => hex(<<16#66:256>>)}),
        {ok, _Finalized, V} = eth_block:finalize(Lying),
        ?assertMatch({unverified, {mismatch, transactions_root, <<16#66:256>>, _}},
                     maps:get(transactions_root, V))
    end).

%% The positive case, so the check is not merely always-fail. A block with no
%% transactions has empty-trie roots for both, and declaring those is correct.
confirms_correct_receipts_root() ->
    with_ctx(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, ?EMPTY_CODE_HASH),
        Parent = store_parent(eth_mpt:state_root()),
        Correct = inbound(Parent, #{<<"receiptsRoot">> => hex(eth_trie:root([])),
                                    <<"transactionsRoot">> => hex(eth_trie:root([]))}),
        {ok, _Finalized, V} = eth_block:finalize(Correct),
        ?assertEqual({verified, eth_trie:root([])}, maps:get(receipts_root, V)),
        ?assertEqual({verified, eth_trie:root([])},
                     maps:get(transactions_root, V))
    end).

%% The transactions root covers only the block's own transaction list, so unlike
%% the state root it is verifiable with no state at all. A node whose parent's
%% state it does not hold must still check it -- refusing to execute is a reason
%% to skip the state root, not a reason to wave the whole block through.
tx_root_needs_no_state() ->
    with_ctx(fun() ->
        Parent = store_parent(<<16#44:256>>),
        {ok, _Finalized, V} =
            eth_block:finalize(inbound(Parent, #{})),
        ?assertEqual({unverified, state_not_local}, maps:get(state_root, V)),
        ?assertEqual({verified, eth_trie:root([])},
                     maps:get(transactions_root, V)),
        %% Receipts do come out of execution, so this one genuinely cannot be
        %% checked here, and saying so beats reporting a root nobody derived.
        ?assertEqual({unverified, not_executed}, maps:get(receipts_root, V))
    end).

%% Every entry has to be a verdict. A bare 32-byte root in a key named after a
%% header field is indistinguishable, to a reader, from a confirmed value, and
%% that ambiguity is what the previous shape relied on.
content_roots_are_verdicts() ->
    with_ctx(fun() ->
        ok = eth_mpt:put_account(?ADDR_A, 1000, 7, ?EMPTY_CODE_HASH),
        Parent = store_parent(eth_mpt:state_root()),
        {ok, _Finalized, V} = eth_block:finalize(inbound(Parent, #{})),
        lists:foreach(
          fun(Key) ->
              ?assertMatch({V1, _} when V1 =:= verified; V1 =:= unverified,
                           maps:get(Key, V))
          end,
          [state_root, transactions_root, receipts_root])
    end).

%% An inbound block, built the way a peer's arrives: from_json/1 over a JSON-RPC
%% header map. Constructing one through the record instead would bypass exactly
%% the path where a peer's declared roots get read, which is the path under test.
inbound(ParentHash, Overrides) ->
    Base = #{<<"parentHash">> => hex(ParentHash),
             <<"number">> => <<"0x1">>,
             <<"timestamp">> => <<"0x64">>,
             <<"gasLimit">> => <<"0x1c9c380">>,
             <<"baseFeePerGas">> => <<"0x3b9aca00">>},
    eth_block:from_json(maps:merge(Base, Overrides)).

%% ---------------------------------------------------------------------------
%% Inbound payloads
%% ---------------------------------------------------------------------------
%% A block arriving from the wire states its commitments. They are carried
%% through unchanged, because checking them is the point -- rewriting them from
%% local state first would make the comparison vacuous.
from_json_carries_declared_commitments() ->
    with_ctx(fun() ->
        Json = eth_block:to_json(eth_block:from_json(sample_block_json())),
        ?assertEqual(hex(<<16#a1:256>>), maps:get(<<"parentHash">>, Json)),
        ?assertEqual(<<"0x2a">>, maps:get(<<"number">>, Json)),
        ?assertEqual(<<"0x64">>, maps:get(<<"timestamp">>, Json)),
        ?assertEqual(<<"0x1c9c380">>, maps:get(<<"gasLimit">>, Json)),
        ?assertEqual(<<"0x3b9aca00">>, maps:get(<<"baseFeePerGas">>, Json)),
        ?assertEqual(hex(<<16#7c:160>>), maps:get(<<"miner">>, Json)),
        ?assertEqual(hex(<<16#55:256>>), maps:get(<<"stateRoot">>, Json)),
        ?assertEqual(hex(<<16#66:256>>), maps:get(<<"transactionsRoot">>, Json)),
        ?assertEqual(hex(<<16#77:256>>), maps:get(<<"receiptsRoot">>, Json))
    end).

%% to_json/1 and from_json/1 must be inverses for the header, or a block
%% round-tripped through a peer would not hash to the same value.
json_roundtrip_test() ->
    Once = eth_block:to_json(eth_block:from_json(sample_block_json())),
    Twice = eth_block:to_json(eth_block:from_json(Once)),
    ?assertEqual(Once, Twice).

sample_block_json() ->
    #{<<"parentHash">> => hex(<<16#a1:256>>),
      <<"number">> => <<"0x2a">>,
      <<"timestamp">> => <<"0x64">>,
      <<"gasLimit">> => <<"0x1c9c380">>,
      <<"baseFeePerGas">> => <<"0x3b9aca00">>,
      <<"miner">> => hex(<<16#7c:160>>),
      <<"extraData">> => <<"0xdeadbeef">>,
      <<"nonce">> => <<"0x0000000000000042">>,
      <<"mixHash">> => hex(<<16#b2:256>>),
      <<"stateRoot">> => hex(<<16#55:256>>),
      <<"transactionsRoot">> => hex(<<16#66:256>>),
      <<"receiptsRoot">> => hex(<<16#77:256>>)}.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

%% Store a block declaring ParentRoot as its state root and return its hash, so
%% a child block can name it as a parent. The header is built with
%% eth_test_util because the chain store recomputes and verifies the hash on
%% append, so the state root has to be substituted before the hash is taken.
store_parent(ParentRoot) ->
    Base = eth_test_util:header(0, hex(<<0:256>>), 0),
    Block = Base#{
              <<"totalDifficulty">> => eth_hex:encode_int(0),
              <<"size">> => eth_hex:encode_int(600),
              <<"stateRoot">> => hex(ParentRoot)
             },
    {ok, HashHex} = eth_header:verify(Block),
    ok = eth_chain:append([{0, Block#{<<"hash">> => HashHex}, true}]),
    hex_to_bin(HashHex).

state_root_of(Block) ->
    hex_to_bin(maps:get(<<"stateRoot">>, eth_block:to_json(Block))).

%% Lowercase, matching eth_header's canonical hash form: the chain store indexes
%% by it, so an uppercase key would silently miss.
hex(B) -> <<"0x", (string:lowercase(binary:encode_hex(B)))/binary>>.

hex_to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest).
