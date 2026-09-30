%% Block data structures and header construction for Phase 3: Block Production.
%%
%% This module defines the execution payload structure and provides
%% header construction, receipt generation, bloom filter computation,
%% and state root verification for blocks produced by etherlang.
%%
%% Post-merge (PoS) block header fields:
%%   parentHash, sha3Uncles, miner, stateRoot, transactionsRoot,
%%   receiptsRoot, logsBloom, difficulty, number, gasLimit, gasUsed,
%%   timestamp, extraData, mixHash, nonce, baseFeePerGas,
%%   withdrawalsRoot, blobGasUsed, excessBlobGas
%%
%% -module(eth_block).

-module(eth_block).

-export([ new/2,
          new/3,
          header/1,
          add_transaction/2,
          declare_state_root/2,
          finalize/1,
          %% Exported for the execution-spec-tests conformance runner, which
          %% needs to apply exactly one transaction to a state it built itself
          %% and read the resulting state and receipt back.
          %%
          %% `finalize/1' cannot serve that: it resolves the parent's state root
          %% through `eth_chain' and then requires the local MPT to *hold* that
          %% root, so it can only run against a block this node synced. A state
          %% test is the opposite case -- a pre-state the runner constructs from
          %% a fixture -- and routing it through `finalize/1' would mean
          %% importing every fixture's pre-state into the trie and resetting it
          %% again per fixture.
          %%
          %% This is not a test-only function: `finalize_against/5' is its
          %% production caller and the whole of block execution goes through it.
          %% What is exported is one transaction's effects, which is the unit
          %% `eth_fork_schedule:current_fork/3,4` and the gas table are already
          %% reasoned about in.
          run_transaction/5,
          %% Exported because the reason vocabulary of an `unverified' verdict is
          %% this module's private vocabulary, and eth_engine has to decide
          %% whether a verdict means "checked, and wrong" or "could not check".
          %% See is_mismatch_verdict/1 for why that decision cannot be made by
          %% pattern-matching those reasons from outside.
          is_mismatch_verdict/1,
          %% Exported so the conformance runner hands `eth_tx:validate/2' the same
          %% blob base fee this module charges at, rather than re-deriving it in
          %% the harness. Two derivations of a consensus constant is the mistake
          %% `eth_evm:base_cost/1' was deleted for, and a harness is exactly where
          %% it would hide.
          blob_base_fee/1,
          from_json/1,
          from_payload/1,
          payload_block_hash/1,
          to_json/1,
          to_payload/1,
          tx_root/1,
          receipts_root/1,
          logs_bloom/1,
          gas_used/1,
          base_fee/0,
          withdrawals_root/0,
          %% The record is module-local, so without these a caller that has
          %% finalized a block cannot read what its transactions did. A JSON-RPC
          %% layer serving eth_getTransactionReceipt and eth_getLogs has no other
          %% way in, which makes the accessors part of the module's contract
          %% rather than a test convenience.
          receipts/1,
          logs/1,
          fork/1,
          %% Exported because hex DATA -> bytes is not a block concern, and
          %% eth_hex:decode/1 cannot do it: it decodes to an *integer*, which is
          %% the right answer for a QUANTITY and never a 32-byte binary or a
          %% transaction. So a caller outside this module that needs the bytes of
          %% a DATA value has to write its own decoder, and eth_engine wrote two.
          %% Both were wrong in the same way -- they used eth_hex:decode/1 and so
          %% could never produce the bytes they were testing for, which made
          %% newPayloadV3 report every real transaction as unreadable and answer
          %% SYNCING where it should have answered INVALID.
          hex_data/1 ]).

-include_lib("etherlang/include/eth_block.hrl").


-define(MAX_GAS, 30000000).
-define(EMPTY_ROOT, <<16#56, 16#e8, 16#1f, 16#17, 16#1b, 16#cc, 16#55, 16#a6,
                       16#ff, 16#83, 16#45, 16#e6, 16#92, 16#c0, 16#f8, 16#6e,
                       16#5b, 16#48, 16#e0, 16#1b, 16#99, 16#6c, 16#ad, 16#c0,
                       16#01, 16#62, 16#2f, 16#b5, 16#e3, 16#63, 16#b4, 16#21>>).

%% Keccak256(RLP([])) -- the hash of an empty ommers list, which every
%% post-Merge block carries in its `sha3Uncles' field because the ommers list is
%% always empty after the Merge.
%%
%% This was ?EMPTY_ROOT, which is Keccak256(RLP(<<>>)) -- the *empty trie* root --
%% so every block this node built carried the trie root in its ommers field, and
%% every block hash it computed was wrong. The two constants differ in all 32
%% bytes, which is what makes this the kind of mistake that survives: the value
%% looks exactly like a hash, is the right length, and is a perfectly good root of
%% something. It was found by decoding a real Paris block and asking why the
%% header it produced did not hash to the hash 6.5 million blocks ago.
-define(EMPTY_UNCLE_HASH, <<16#1d, 16#cc, 16#4d, 16#e8, 16#de, 16#c7, 16#5d,
                            16#7a, 16#ab, 16#85, 16#b5, 16#67, 16#b6, 16#cc,
                            16#d4, 16#1a, 16#d3, 16#12, 16#45, 16#1b, 16#94,
                            16#8a, 16#74, 16#13, 16#f0, 16#a1, 16#42, 16#fd,
                            16#40, 16#d4, 16#93, 16#47>>).

%% ---------------------------------------------------------------------------
%% Block construction
%% ---------------------------------------------------------------------------

new(ParentHash, Number) ->
    #block{
        parent_hash = ParentHash,
        number = Number,
        timestamp = erlang:system_time(second),
        miner = <<0:160>>,
        difficulty = 0,
        total_difficulty = undefined,
        gas_limit = ?MAX_GAS,
        gas_used = 0,
        transactions = [],
        receipts = [],
        logs = [],
        logs_bloom = eth_bloom:new(),
        state_root = ?EMPTY_ROOT,
        receipts_root = ?EMPTY_ROOT,
        transactions_root = ?EMPTY_ROOT,
        blob_gas_used = 0,
        excess_blob_gas = 0,
        withdrawals = [],
        withdrawals_root = ?EMPTY_ROOT,
        parent_beacon_block_root = undefined,
        extra_data = <<>>,
        %% 8 bytes. This was <<0:192>>, which is 192 *bits* -- 24 bytes -- and
        %% the nonce is 8. RLP prefixes a string by its length, so a 24-byte
        %% nonce makes the header 16 bytes longer than the header the network
        %% hashed, and every block hash this node computes is wrong. Found by
        %% decoding a real post-Merge block and asking why a header that decoded
        %% field for field to the block's own values did not hash to the block's
        %% own hash.
        nonce = <<0:64>>,
        mix_hash = <<0:256>>,
        sha3_uncles = ?EMPTY_UNCLE_HASH
    }.

%% new/3 attaches a base fee, which new/2 cannot know on its own.
new(ParentHash, Number, BaseFee) ->
    (new(ParentHash, Number))#block{base_fee_per_gas = BaseFee}.

add_transaction(Block, Tx) ->
    Block#block{transactions = Block#block.transactions ++ [Tx]}.

receipts(#block{receipts = R}) -> R.

logs(#block{logs = L}) -> L.

%% The fork whose rules apply to this block. Exposed because a caller deciding
%% how to interpret a payload -- whether a beacon root is present, whether
%% withdrawals may be non-empty -- needs the same answer execution used, not a
%% second derivation of it that could disagree.
fork(#block{} = Block) ->
    fork_of(Block).

%% Record the state root an inbound block declares. A locally built block leaves
%% this at the ?EMPTY_ROOT sentinel, which finalize/1 reads as "no declaration
%% yet"; a block arriving from the consensus layer states one, and finalize/1
%% checks it against what execution actually produced.
declare_state_root(Block, Root) when is_binary(Root), byte_size(Root) =:= 32 ->
    Block#block{state_root = Root}.

%% from_json/1 builds a block from a JSON-RPC block map, so a payload received
%% over the wire can be executed without a hand-transcription of every field.
%% Values that are not present keep the defaults from new/2; the commitments
%% are left as sent, because they are what is being checked.
from_json(Map) when is_map(Map) ->
    Block0 = new(to_bin(maps:get(<<"parentHash">>, Map, <<0:256>>)),
                uint(maps:get(<<"number">>, Map, 0)),
                uint_or_undefined(maps:get(<<"baseFeePerGas">>, Map, undefined))),
    Block1 = Block0#block{
        timestamp = uint(maps:get(<<"timestamp">>, Map, 0)),
        miner = to_address(maps:get(<<"miner">>, Map, <<0:160>>)),
        difficulty = uint(maps:get(<<"difficulty">>, Map, 0)),
        total_difficulty = uint_or_undefined(maps:get(<<"totalDifficulty">>, Map, undefined)),
        gas_limit = uint(maps:get(<<"gasLimit">>, Map, ?MAX_GAS)),
        extra_data = to_bytes(maps:get(<<"extraData">>, Map, <<>>)),
        nonce = to_bytes(maps:get(<<"nonce">>, Map, <<0:192>>)),
        mix_hash = to_bytes(maps:get(<<"mixHash">>, Map, <<0:256>>))
    },
    Block2 = maybe_declare(Block1, maps:get(<<"stateRoot">>, Map, undefined)),
    Block3 = maybe_declare(Block2, maps:get(<<"transactionsRoot">>, Map, undefined),
                           transactions_root),
    Block4 = maybe_declare(Block3, maps:get(<<"receiptsRoot">>, Map, undefined),
                           receipts_root),
    Block4#block{
        withdrawals = withdrawals_from_json(maps:get(<<"withdrawals">>, Map, [])),
        parent_beacon_block_root =
            maybe_word(maps:get(<<"parentBeaconBlockRoot">>, Map, undefined))
    }.

%% The parent beacon block root is 32 bytes, or absent. A payload that carries
%% something else is a malformed one; leaving it undefined would make the
%% EIP-4788 call silently not happen, so it is dropped to undefined only for
%% genuinely absent values and kept as a word otherwise.
maybe_word(undefined) -> undefined;
maybe_word(V) when is_binary(V), byte_size(V) =:= 66 ->
    binary:decode_hex(binary:part(V, 2, 64));
maybe_word(V) when is_binary(V), byte_size(V) =:= 32 -> V;
maybe_word(_) -> undefined.

withdrawals_from_json(Ws) when is_list(Ws) -> [normalize_withdrawal(W) || W <- Ws];
withdrawals_from_json(_) -> [].

normalize_withdrawal(W) when is_map(W) ->
    #{index => withdrawal_quantity(maps:get(<<"index">>, W, 0)),
      validatorIndex => withdrawal_quantity(
                          maps:get(<<"validatorIndex">>, W,
                                   maps:get(<<"validator_index">>, W, 0))),
      address => withdrawal_address_bytes(maps:get(<<"address">>, W, <<>>)),
      amount => withdrawal_quantity(maps:get(<<"amount">>, W, 0))};
normalize_withdrawal(_) ->
    #{index => 0, validatorIndex => 0, address => <<0:160>>, amount => 0}.

%% The wire form is a JSON-RPC quantity, so "0x175" is hexadecimal 373.
withdrawal_quantity(V) when is_integer(V) -> max(0, V);
withdrawal_quantity(V) when is_binary(V) ->
    try max(0, eth_hex:decode(V)) catch _:_ -> 0 end;
withdrawal_quantity(_) -> 0.

withdrawal_address_bytes(<<A:20/binary>>) -> A;
withdrawal_address_bytes(<<"0x", Rest/binary>>) when byte_size(Rest) =:= 40 ->
    binary:decode_hex(Rest);
withdrawal_address_bytes(_) -> <<0:160>>.

maybe_declare(Block, undefined) -> Block;
maybe_declare(Block, Hex) when is_binary(Hex), byte_size(Hex) =:= 66 ->
    declare_state_root(Block, binary:decode_hex(binary:part(Hex, 2, 64))).

maybe_declare(Block, undefined, _Field) -> Block;
maybe_declare(Block, Hex, Field) when is_binary(Hex), byte_size(Hex) =:= 66 ->
    Root = binary:decode_hex(binary:part(Hex, 2, 64)),
    case Field of
        transactions_root -> Block#block{transactions_root = Root};
        receipts_root -> Block#block{receipts_root = Root}
    end.

to_bin(<<"0x", _/binary>> = H) -> hex_to_bin(H);
to_bin(B) when is_binary(B) -> B;
to_bin(_) -> <<>>.

uint_or_undefined(undefined) -> undefined;
uint_or_undefined(V) -> uint(V).

%% finalize/1 executes the block body and then recomputes every commitment the
%% header asserts. The commitments are not equally trustworthy, so they are
%% reported separately.
%%
%%   * transactions_root and receipts_root derive from the block's own contents
%%     (the transaction list, and the receipts those transactions produced), so a
%%     node that executed the body can recompute both and check them. This one
%%     did compute them and did not check them, which reported a self-consistent
%%     number under a name that reads as if it had been confirmed.
%%
%%   * state_root is different. A genuine post-state root exists only if the
%%     node holds the *parent's* state locally, executes against it, and writes
%%     the result back. This node generally does not: reads normally come from
%%     an upstream peer, and there is no post-state trie to hash in that case.
%%
%% finalize/1 therefore does not stamp a state root it cannot justify. It first
%% requires the local MPT to hold exactly the parent's state -- checked by
%% comparing the MPT's own recomputed root against the parent's declared root,
%% not by a "loaded" flag that a later write could invalidate -- and then either
%% verifies the declared root or explains why it could not.
%%
%% Returns {ok, Block, Verification}, where
%%   Verification :: #{state_root      := {verified, Root} | {unverified, Reason},
%%                    transactions_root := {verified, Root} | {unverified, Reason},
%%                    receipts_root     := {verified, Root} | {unverified, Reason},
%%                    gas_used          := Gas}
%% A caller that must not accept an unverifiable block reads this map rather
%% than trusting the block's own root fields. Every entry is a verdict on a
%% declared value, never the recomputed value presented as if it were the
%% declared one.
finalize(#block{transactions = Txs,
                gas_limit = GasLimit,
                base_fee_per_gas = BaseFee} = Block) ->
    case parent_state_root(Block) of
        {error, Reason} ->
            {error, Reason};
        {ok, ParentRoot} when not is_binary(ParentRoot) ->
            {error, {invalid_parent, ParentRoot}};
        {ok, ParentRoot} ->
            finalize_against(Block, ParentRoot, Txs, GasLimit, BaseFee)
    end.

%% The chain store indexes blocks by their canonical 0x-hex hash, while the
%% record holds hashes as raw bytes (as every other hash in #block{} does). The
%% two encodings have to be bridged here; passing the raw bytes would look up a
%% key that cannot exist, and the block would always report an unknown parent.
parent_state_root(#block{parent_hash = ParentHash}) ->
    Key = to_hex(ParentHash),
    Fetched = try eth_chain:get_by_hash(Key)
              catch _:_ -> unavailable
              end,
    case Fetched of
        {ok, ParentMap, _Full} when is_map(ParentMap) ->
            case maps:get(<<"stateRoot">>, ParentMap, undefined) of
                undefined -> {error, {unknown_parent, no_state_root}};
                Root -> {ok, to_bin(Root)}
            end;
        _ ->
            {error, {unknown_parent, ParentHash}}
    end.

finalize_against(Block, ParentRoot, Txs, GasLimit, BaseFee) ->
    case local_holds(ParentRoot) of
        false ->
            %% Executing here would produce a root over whatever subset of the
            %% state happens to be local. Publishing that as the block's state
            %% root is the worst outcome available: a plausible value that is
            %% silently wrong. The transactions root is the exception -- it
            %% covers only the block's own transaction list, so it is verifiable
            %% without the parent's state and is checked here. The receipts root
            %% is not, because receipts come out of execution.
            {ok, commitments(Block),
             #{state_root => {unverified, state_not_local},
               transactions_root =>
                   check_transactions_root(Block#block.transactions_root,
                                           tx_root(Block#block.transactions)),
               receipts_root => {unverified, not_executed}}};
        true ->
            Previous = eth_state:base_source(),
            ok = eth_state:set_base_source(mpt),
            try
                State = eth_state:new(Block#block.parent_hash, #{}),
                %% System operations run in the order the forks specify: the
                %% two system-contract calls open the block, before any
                %% transaction can observe them, and withdrawals close it, after
                %% the last transaction. All three write the same overlay the
                %% transactions do, so all three are inside the state root this
                %% block declares.
                %%
                %% The two system calls are not ordered relative to each other:
                %% neither is charged to the block gas limit and they write
                %% disjoint storage in disjoint accounts, so either order gives
                %% the same state. The parent hash is recorded first so a
                %% transaction in this block can already read this block's own
                %% parent through the history contract.
                Fork = fork_of(Block),
                {ok, StateH} = eth_fork_schedule:process_history(
                                  Block#block.parent_hash,
                                  Block#block.number,
                                  State, Fork),
                {ok, State0} = eth_fork_schedule:process_beacon_roots(
                                  Block#block.timestamp,
                                  Block#block.parent_beacon_block_root,
                                  StateH, Fork),
                case execute_transactions(Block, Txs, State0,
                                           BaseFee, GasLimit, 0) of
                    {error, _} = Invalid ->
                        %% A block whose body contains a transaction that is not
                        %% valid is not a block, so there is nothing to report a
                        %% Verification for. The state is deliberately not
                        %% committed either: the system calls above did run, but
                        %% committing a half-executed block's state would leave
                        %% the trie holding a root that corresponds to no block
                        %% anyone will ever ask for.
                        Invalid;
                    {ok, Executed, StateT} ->
                        {ok, State1, _Applied} =
                            eth_fork_schedule:apply_withdrawals_to_state(
                              Executed#block.withdrawals, StateT),
                        case eth_state:commit(State1) of
                            ok ->
                                Root = eth_mpt:state_root(),
                                Verification = #{state_root =>
                                                     check_state_root(Executed#block.state_root,
                                                                      Root),
                                                 transactions_root =>
                                                     check_transactions_root(
                                                       Executed#block.transactions_root,
                                                       tx_root(Executed#block.transactions)),
                                                 receipts_root =>
                                                     check_receipts_root(
                                                       Executed#block.receipts_root,
                                                       receipts_root(Executed#block.receipts)),
                                                 gas_used => Executed#block.gas_used},
                                {ok, commitments(Executed, Root), Verification};
                            {error, Reason} ->
                                {ok, commitments(Executed),
                                 #{state_root => {unverified, {commit_failed, Reason}},
                                   transactions_root =>
                                       check_transactions_root(
                                         Executed#block.transactions_root,
                                         tx_root(Executed#block.transactions)),
                                   receipts_root =>
                                       check_receipts_root(
                                         Executed#block.receipts_root,
                                         receipts_root(Executed#block.receipts)),
                                   gas_used => Executed#block.gas_used}}
                        end
                end
            after
                _ = eth_state:set_base_source(Previous)
            end
    end.

%% The rules in force for this block, which decide which system calls apply.
%% There is no network here to consult, so the schedule is asked for this block's
%% own position.
%%
%% current_fork/3 answers {ok, Fork}. This used to match that against a bare-atom
%% pattern, which can never match, so every block was reported as `paris' --
%% including blocks at Cancun and later. paris is in neither EIP-4788's nor
%% EIP-2935's active-fork list, so both system calls were skipped for every
%% block at every fork, and the computed state root disagreed with every other
%% client's. Nothing caught it, because the tests for those calls invoke
%% eth_fork_schedule directly with an explicit fork argument and so never go
%% through this.
fork_of(#block{number = Number, timestamp = Ts, total_difficulty = TD}) ->
    try eth_fork_schedule:current_fork(
          eth_fork_schedule:configured_network(), Number, Ts, TD) of
        {ok, Fork} when is_atom(Fork) -> Fork;
        Fork when is_atom(Fork) -> Fork;
        _ -> paris
    catch
        _:_ -> paris
    end.

%% The local MPT holds the parent's state exactly when its own root equals the
%% root that block declares. This compares recomputed roots on purpose.
local_holds(ParentRoot) when is_binary(ParentRoot) ->
    try eth_mpt:state_root() =:= ParentRoot
    catch _:_ -> false
    end;
local_holds(_) ->
    false.

%% A block being built locally starts from the ?EMPTY_ROOT sentinel, meaning "no
%% state root declared yet", and adopts the computed one. An inbound payload
%% declares a root, which must match what execution produced.
check_state_root(?EMPTY_ROOT, Computed) ->
    {verified, Computed};
check_state_root(undefined, Computed) ->
    {verified, Computed};
check_state_root(Declared, Computed) when is_binary(Declared) ->
    case Declared =:= Computed of
        true -> {verified, Computed};
        false -> {unverified, {mismatch, Declared, Computed}}
    end;
check_state_root(_Declared, _Computed) ->
    {unverified, invalid_declared_root}.

%% The receipts and transactions roots are verifiable without any local state:
%% both are Merkle roots over the block's own contents, so a node that executed
%% the body can recompute them and compare. Reporting only the recomputed value
%% -- which is what this used to do -- is not verification at all: a block
%% declaring a wrong receipts root passed silently, because the number the
%% caller saw was the one this node had just computed rather than the one that
%% was claimed. The verdict carries the computed root, so a caller that wants the
%% value still has it, and says which of the two it is.
check_receipts_root(Declared, Computed) when is_binary(Computed) ->
    check_commitment(receipts_root, Declared, Computed).

check_transactions_root(Declared, Computed) when is_binary(Computed) ->
    check_commitment(transactions_root, Declared, Computed).

%% ?EMPTY_ROOT is the sentinel from new/2 for a block this node built itself,
%% which has no declaration to check. Treating it as a declaration would report
%% every locally authored block as a mismatch against the empty trie.
check_commitment(_Which, ?EMPTY_ROOT, Computed) ->
    {verified, Computed};
check_commitment(_Which, undefined, Computed) ->
    {verified, Computed};
check_commitment(Which, Declared, Computed) when is_binary(Declared) ->
    case Declared =:= Computed of
        true -> {verified, Computed};
        false -> {unverified, {mismatch, Which, Declared, Computed}}
    end;
check_commitment(Which, _Declared, _Computed) ->
    {unverified, {invalid_declared, Which}}.

%% Does this verdict mean "checked, and the value is wrong", as opposed to
%% "could not be checked"?
%%
%% It has to be asked here rather than by the caller, because the two verdicts are
%% not distinguishable from the `unverified' tag alone -- both are
%% `{unverified, Reason}' -- and the reasons are not one shape. There are five,
%% and they were written at three different places in this module:
%%
%%   {unverified, state_not_local}              -- checked nothing (finalize/1)
%%   {unverified, not_executed}                 -- checked nothing (finalize/1)
%%   {unverified, {commit_failed, _}}           -- checked nothing (commit path)
%%   {unverified, {mismatch, Declared, Computed}}          -- WRONG (3-tuple)
%%   {unverified, {mismatch, Which, Decl, Comp}}          -- WRONG (4-tuple)
%%   {unverified, invalid_declared_root}                  -- WRONG (bare atom)
%%   {unverified, {invalid_declared, Which}}              -- WRONG (2-tuple)
%%
%% The state root's mismatch is a 3-tuple while the content roots' is a 4-tuple,
%% because check_state_root/2 predates check_commitment/3 and neither was changed
%% to match the other. eth_engine pattern-matched only the 4-tuple and the
%% `{invalid_declared, _}' pair, so a payload declaring a wrong *state root* -- the
%% commitment the node is most entitled to have an opinion about -- fell through
%% to the unchecked branch and was answered SYNCING. That is the specific
%% inversion this function exists to make impossible: a client told SYNCING for a
%% block this node had already found bad will keep retrying it forever.
%%
%% A new `{unverified, ...}' reason must be added here explicitly. Silence means
%% SYNCING, which is the safe direction to fail in -- but a wrong value reported
%% as unchecked is still a wrong answer.
is_mismatch_verdict({unverified, {mismatch, _, _}}) -> true;
is_mismatch_verdict({unverified, {mismatch, _, _, _}}) -> true;
is_mismatch_verdict({unverified, invalid_declared_root}) -> true;
is_mismatch_verdict({unverified, {invalid_declared, _}}) -> true;
is_mismatch_verdict({unverified, _}) -> false;
is_mismatch_verdict(_) -> false.

%% Recompute the content-derived commitments. The block's own state_root field is
%% left alone here; it is only set by commitments/2, and only once a root has
%% been justified.
commitments(#block{} = Block) ->
    Block#block{
        gas_used = sum_gas_used(Block#block.receipts),
        logs_bloom = compute_bloom(Block#block.logs),
        receipts_root = receipts_root(Block#block.receipts),
        transactions_root = tx_root(Block#block.transactions)
    }.

commitments(#block{} = Block, Root) ->
    (commitments(Block))#block{state_root = Root}.

%% ---------------------------------------------------------------------------
%% Transaction execution
%% ---------------------------------------------------------------------------

%% Returns the block and the post-execution state, or {error, ...} if the block
%% is not a valid block. The state is threaded rather than discarded: without it
%% every transaction in a block sees the pre-block state, so the transactions in
%% a block cannot build on each other at all.
%%
%% Every transaction is checked for validity *before* it runs, against the state
%% as it stands at that point in the block. This is not an optimisation. A block
%% whose body contains a transaction with a bad nonce, an unfunded sender, a
%% foreign chain id, a gas limit below its own intrinsic cost, or a signature
%% that does not recover is not a block at all, and executing it anyway produces
%% a state root that no other client can reproduce -- and worse, a plausible one
%% that gets stored and served as if it were real. Validating first turns that
%% into a refusal, which is recoverable.
%%
%% The checks are in eth_tx:validate/2, the same function the block builder and
%% the transaction pool use, so there is one answer to "is this transaction
%% valid" rather than three that can disagree about intrinsic gas.
execute_transactions(Block, [], State, _BF, _GL, _BlobGasUsed) ->
    {ok, Block, State};
execute_transactions(#block{base_fee_per_gas = BaseFee, gas_limit = GL} = Block,
                 [Tx | Rest], State, _BF, GL, BlobGasUsed) ->
    Index = length(Block#block.receipts),
    case eth_tx:validate(Tx, validation_ctx(Block, State, BaseFee, GL, BlobGasUsed)) of
        {error, Reason} ->
            {error, {invalid_transaction, Index, Reason}};
        ok ->
            case run_transaction(Block, Tx, State, BaseFee, GL) of
                {error, _} = Err -> Err;
                {Block1, State1} ->
                    %% EIP-4844's per-block cap is **cumulative**, so the total has
                    %% to be carried forward rather than read off the block. The two
                    %% corpus fixtures that need this carry 7 and 9 versioned hashes,
                    %% and a *per-transaction* check would not catch either: a
                    %% 4-blob transaction followed by a 3-blob one is an invalid block
                    %% whose transactions are each valid.
                    Next = BlobGasUsed + blob_gas_of(Tx),
                    execute_transactions(Block1, Rest, State1, BaseFee, GL, Next)
            end
    end.

%% A transaction's own blob gas: `GAS_PER_BLOB * len(blob_versioned_hashes)`, zero for
%% a transaction of any other type. The same arithmetic as `blob_fee/2' divided by the
%% price, and deliberately **not** shared with it: that one is a wei amount and this
%% one is a gas quantity, so a helper deriving one from the other would divide by a
%% price that is 1 only at the floor.
blob_gas_of(Tx) ->
    case eth_tx:tx_type(Tx) of
        eip4844 -> length(eth_tx:blob_versioned_hashes(Tx))
                      * eth_fork_schedule:blob_gas_per_blob();
        _ -> 0
    end.

%% What validity needs that the transaction does not carry. The base fee and gas
%% limit come from the block header, the chain id from this node's configuration
%% (never from eth_state:chain_id/0, which asks the upstream peer -- a peer's
%% answer is not a rule), and balance and nonce from the state being executed
%% against, which is the state as of *this* point in the block rather than its
%% start, so a block whose second transaction spends the first one's balance
%% sees the reduced balance.
validation_ctx(Block, State, BaseFee, GasLimit, BlobGasUsed) ->
    #{base_fee => BaseFee,
      gas_limit => GasLimit,
      gas_used => Block#block.gas_used,
      chain_id => eth_fork_schedule:chain_id(),
      %% The block's own fork, so EIP-3860's init-code term is charged under the
      %% rules of the block being validated rather than under whatever the
      %% operator pinned. Without it a pre-Shanghai block's creation transaction
      %% is refused for carrying 2 gas per word of gas it does not owe.
      fork => fork(Block),
      balance_of => fun(Address) ->
          {ok, maps:get(balance, eth_state:account(State, Address), 0)}
      end,
      nonce_of => fun(Address) ->
          {ok, maps:get(nonce, eth_state:account(State, Address), 0)}
      end,
      %% EIP-3607 needs the sender's **code**, not its balance or nonce, and a context
      %% that carried only those two would let a transaction from a contract through
      %% every check in `eth_tx:validate/2'. This is the admission path -- a block's own
      %% transactions -- so the omission here would have made the rule a fixture-only
      %% improvement while the node still imported such a transaction from a peer.
      code_of => fun(Address) ->
          {ok, maps:get(code, eth_state:account(State, Address), <<>>)}
      end,
      %% EIP-4844: "ensure that the user was willing to at least pay the current
      %% blob base fee". The price is this block's own `blob_base_fee/1' -- the
      %% same function `blob_fee/2' charges at -- and it is supplied here because
      %% `eth_tx:check_blobs/2' reads it from the context rather than from the
      %% block, and **no caller was passing it**, so the rule could not fire on
      %% any transaction including this node's own blocks. A rule nobody can
      %% reach is not a rule; see the EIP-3607 note above for the same shape.
      blob_base_fee => blob_base_fee(Block),
      %% EIP-4844's per-block cap, cumulative, so the context carries the running
      %% total. It is an argument rather than `Block#block.blob_gas_used' because
      %% that field holds the block's **declared** header value on an imported
      %% payload: writing an executed total into it would put a recomputed number
      %% under a key named after a header field, which is the one thing AGENTS.md
      %% 4.1 exists to prevent. The limit and the commitment are two questions --
      %% "may this block carry this much" and "does this block's header tell the
      %% truth" -- and they must not share a stored value.
      blob_gas_used => BlobGasUsed}.

%% The frame's own outcome, with "this node cannot price this" kept separate.
%%
%% An EVM crash is an exceptional halt, which consumes the whole gas limit and discards
%% the frame. It is not the same as a revert, which is a deliberate failure the caller
%% can observe in the return data, and must not be recorded as one.
run_frame(Code, Msg, State, Env, EvmGas, TxIntrinsic, AuthRefund) ->
    try eth_evm:run(Code, Msg, State, Env, EvmGas, TxIntrinsic, AuthRefund) of
        {ok, Out, GL, St, L} ->
            {ok, Out, GL, St, L};
        {revert, Out1, GL1, St1, L1} ->
            {revert, Out1, GL1, St1, L1};
        {error, {unsupported, What}, _St2, _L3} ->
            {error, {unpriced, What}};
        {error, _Reason, St2, _L2} ->
            {error, <<>>, 0, St2, []}
    catch
        _:_ -> {error, <<>>, 0, State, []}
    end.

run_transaction(#block{} = Block, Tx, State, BaseFee, GL) ->
    GasLimitTx = uint(maps:get(<<"gas">>, Tx, GL)),
    Value = uint(maps:get(<<"value">>, Tx, 0)),
    To = to_address(maps:get(<<"to">>, Tx, <<>>)),
    %% Through `eth_tx:calldata/1' and not a local read of `input'. This read
    %% `input' alone, while the JSON-RPC field is `data' and `eth_tx:from_rlp/1' emits
    %% `input' -- so a transaction carrying `data' was executed with no calldata
    %% while `eth_tx:intrinsic_gas/5' charged for the calldata. See that function.
    Data = eth_tx:calldata(Tx),
    %% **`undefined`, not 0, when the field is absent.** These two were read with a
    %% default of 0, which made a *legacy* transaction -- one that has no
    %% `maxFeePerGas' and no `maxPriorityFeePerGas' at all -- indistinguishable from a
    %% 1559 transaction that explicitly asks for a zero fee. `effective_gas_price/4'
    %% then took its 1559 clause and answered `min(0, BaseFee + 0)' = **0**.
    %%
    %% The consequence is the whole gas limit, and it is why the conformance corpus
    %% showed twenty fixtures at `spent_actual = 1000000` and nothing else:
    %%
    %%   * `gas_ceiling/1' charges the sender `gasLimit * gasPrice' -- 1,000,000 * 10;
    %%   * `settle_gas/8' refunds `GasLeft * EffectiveGasPrice' -- `GasLeft * 0`;
    %%   * so the sender is billed the entire allowance for gas it did not use.
    %%
    %% The boundary is London because that is the first fork with a base fee, and
    %% `undefined' is the only value that says "this block has no base fee, so the
    %% 1559 clause does not apply". Berlin and earlier were correct by accident: with
    %% no base fee the function returned `gasPrice' before the guard was reached.
    %%
    %% A zero max fee is a real, valid thing for a 1559 transaction to say, and it is
    %% handled as one below -- at the floor, and rejected by `fee_ceiling_ok/4' for
    %% being below it. Collapsing "absent" into "zero" is what made it indistinguishable.
    MaxPriorityFee = opt_uint(maps:get(<<"maxPriorityFeePerGas">>, Tx, undefined)),
    MaxFee = opt_uint(maps:get(<<"maxFeePerGas">>, Tx, undefined)),
    GasPrice = uint(maps:get(<<"gasPrice">>, Tx, 0)),
    EffectiveGasPrice = effective_gas_price(GasPrice, MaxPriorityFee, MaxFee, BaseFee),
    %% The sender is the recovered signer, not the transaction's own `from'
    %% field. Finalizing a block means deciding what state its transactions
    %% produced, and trusting a self-declared sender would let a malformed body
    %% move a third party's balance.
    Sender = case eth_tx:sender(Tx) of
        {ok, A} -> A;
        _ -> error({cannot_finalize, unrecoverable_sender})
    end,
    %% A transaction with no destination creates a contract. The address is
    %% keccak(rlp([sender, nonce]))[12:], which is why the nonce is read here
    %% rather than after the bump below: the pre-transaction nonce is the input.
    IsCreate = (To =:= <<>>),
    Nonce = eth_state:nonce(State, Sender),
    ContractAddress = create_address(Sender, Nonce),
    Target = case IsCreate of true -> ContractAddress; false -> To end,
    %% The block's own fork, not eth_tx's configured_fork/0 fallback: EIP-3860's
    %% init-code term is Shanghai's, so a pre-Shanghai block's creation
    %% transactions are charged without it. The fallback is right for admission,
    %% where no block exists, and wrong here, where one does.
    Intrinsic = eth_tx:intrinsic_gas(Tx, fork(Block)),
    %% Everything a transaction does to state outside the EVM's own frame. The
    %% EVM only executes code; the nonce bump, the value transfer, the gas
    %% purchase and the coinbase payment are the *transaction*'s effects, and
    %% omitting them leaves a post-state that no other client can reproduce even
    %% when the code ran perfectly. Without the nonce bump a second transaction
    %% from the same sender cannot validate, because the account nonce never
    %% moves; without the gas purchase the coinbase is never credited.
    State0 = begin_transaction(State, Sender, Target, Value,
                                GasLimitTx, IsCreate, EffectiveGasPrice,
                                blob_fee(Block, Tx)),
    %% EIP-7702: "The authorization list is processed before the execution portion
    %% of the transaction begins, but after the sender's nonce is incremented."
    %% `begin_transaction/8' is what increments the sender's nonce, so this sits
    %% immediately after it and immediately before the frame -- which is the only
    %% placement that is both "after the nonce" and "before the execution".
    %%
    %% **And it is here that the EIP's one surprise lives**, which is worth stating
    %% because the obvious implementation gets it backwards: "if transaction execution
    %% results in failure (e.g. any exceptional condition or code reverting), the
    %% processed delegation indicators is *not rolled back*."
    %%
    %% That falls out of where this call sits. A revert restores the state the frame
    %% started from, and the frame starts from `State0` -- which is *after* the
    %% authorizations. So the delegations survive a revert without any special case
    %% here, and putting this call *inside* the frame's starting state instead would
    %% roll them back and diverge on exactly the transactions that fail.
    {StateAuth, AuthAuthorities, AuthRefund} =
        process_authorizations(State0, Tx, fork(Block)),
    %% The EVM runs with what the intrinsic cost left, never the full limit.
    EvmGas = max(0, GasLimitTx - Intrinsic),
    %% The EVM reads its message and environment through atom keys (s_msg/3,
    %% s_env/3 in eth_evm). Passing the JSON-RPC spelling instead meant every
    %% lookup missed and fell back to its default: the contract saw no
    %% calldata at all, CALLER was the zero address, and TIMESTAMP, NUMBER,
    %% PREVRANDAO, GASLIMIT and BASEFEE all read as 0. Nothing crashed, and
    %% every one of those is load-bearing for the state root.
    %% EIP-7702's fifth affected operation: "any transaction where `destination`
    %% points to an address with a delegation indicator present". So a transaction
    %% to a delegated account runs the delegate's code **in the context of the
    %% account**: `Target` is the frame's address, its storage and its balance
    %% below, and only `Code` comes from the delegate. That difference is the whole
    %% point of the feature, and it is why `Target` is not re-pointed at the
    %% delegate anywhere in this function -- doing so would make a delegation an
    %% ordinary call to the delegate, the opposite of what it authorises.
    %%
    %% **Resolved here, before the Msg**, because the Msg carries `delegate' for
    %% the warm set. The first version of this edit put the resolution at the old
    %% `Code = ...' line, some forty lines *below* the Msg, and the compiler said
    %% `move the binding of TxDelegate out of the map' -- which is the polite form
    %% of "you read this variable before you wrote it". A warning about an
    %% exported-from-subexpression binding is, in a build where warnings are
    %% errors, the build catching a use-before-bind.
    {Code, TxDelegate} =
        case IsCreate of
            true -> {Data, undefined};
            false -> eth_tx:resolve_delegation(State0, Target, fork(Block))
        end,
    Msg = #{
        caller => Sender,
        origin => Sender,
        address => Target,
        value => Value,
        data => Data,
        gas_price => EffectiveGasPrice,
        static => false,
        depth => 0,
        %% EIP-7702: "if a transaction's `destination` has a delegation indicator,
        %% add the target of the delegation to `accessed_addresses`."
        %%
        %% Carried on the **Msg** and read by `eth_evm:initial_access/3`, which is
        %% the one function that decides the transaction-start warm set, rather than
        %% as a warm entry planted in the Env. Two reasons, and the first is the
        %% load-bearing one: `initial_access/3` builds the set from the Msg and the
        %% Env and has no other input, so an Env-only entry would be dropped and the
        %% delegate would be cold again on the very first access. A key nobody reads
        %% is the `check_blobs/2` shape from AGENTS.md §10a -- a careful clause
        %% around a hole.
        %%
        %% Without this the delegate is warm from the first frame onward where the
        %% specification makes it cold, so every *later* access to it in the same
        %% transaction is under-charged by 2,500 -- an error visible only on a
        %% transaction that touches the delegate twice, which is why it needs its own
        %% test rather than falling out of a gas total.
        delegate => TxDelegate,
        %% EIP-7702 step 4's `accessed_addresses` additions, one per **recovered**
        %% authority. Read by `eth_evm:initial_access/3' beside `delegate'.
        auth_authorities => AuthAuthorities,
        %% EIP-2930's access list, in the frame, because the frame is where it has to
        %% act. `eth_tx:access_list_field/1' is the **same function `validate/2`
        %% priced**, so the list that is charged for and the list that is applied cannot
        %% disagree -- which is the whole reason it is called rather than re-derived.
        %%
        %% It was priced and never applied. `intrinsic_gas/2` charges
        %% `ACCESS_LIST_ADDRESS_COST * n + ACCESS_LIST_STORAGE_KEY_COST * k` correctly --
        %% 21,000 -> 29,600 on `eip2930_access_list/test_repeated_address_acl`, a
        %% difference of exactly 8,600 = `2400*2 + 1900*2` -- and nothing anywhere put the
        %% entries in the warm sets. So a sender who declared an access paid for it
        %% twice: once in the intrinsic, and again as a cold access on every use.
        %%
        %% The corpus figure is `+4,000` on six fixtures plus three `test_chainid`
        %% entries, and `4,000` is exactly `(COLD_SLOAD_COST - WARM_STORAGE_READ_COST) *
        %% 2` = `(2,100 - 100) * 2` -- two cold `SLOAD`s of slots the list had already
        %% paid to warm, with **no intrinsic term**, which is what confirmed the
        %% intrinsic was right and the application was what was missing.
        access_list => eth_tx:access_list_field(Tx)
    },
    %% Code is read through the same state view the EVM executes against.
    %% Fetching it from a separate store would let a call run against code that
    %% the state it runs in says does not exist.
    %%
    %% A creation is the one case where the code to run is *not* the account's:
    %% the calldata is the init code, and it runs at the address the create
    %% derives. Its return value is the deployed code, which is installed below
    %% only if the frame succeeded.
    Env = block_env(Block, State0),
    %% **A halt that means "this node cannot price this" is not a transaction
    %% failure, and committing it as one is the worst thing available here.**
    %%
    %% `unsupported' is raised when the interpreter meets an operation whose schedule it
    %% does not have -- pre-Berlin SSTORE is the live case, refused because there are
    %% three pre-Berlin SSTORE schedules and only EIP-2200's text is implemented. The
    %% refusal was written for `eth_call', where it degrades to an upstream answer, and
    %% there it is right. In block execution it did the opposite: the reason was
    %% discarded, the halt was recorded as an ordinary error, the transaction was
    %% charged its **whole** gas limit, and the block's state root was committed as
    %% though the chain had reached that outcome.
    %%
    %% The corpus found it as the largest single divergence it had: two fixtures in
    %% `byzantium/eip197_ec_pairing' whose nineteen-byte callee spends 979,000 of a
    %% 979,000 allowance that the chain spends in 35,723, with
    %% `{unsupported, {sstore, istanbul}}' underneath. Running that callee directly is
    %% what named the cause: the call to the pairing check is fine, and the SSTORE that
    %% stores its return value is the whole of it.
    %%
    %% `execute_transactions/5' already refuses to commit a block whose body contains a
    %% transaction it cannot execute, and deliberately does not commit the state either.
    %% This joins that path: a block this node cannot produce is *reported*, not
    %% produced. Pricing the pre-Berlin SSTORE is the real fix and is still open
    %% (TASKS.md) -- but until it is done, refusing is the honest answer and executing
    %% wrongly is not.
    %% **The intrinsic goes in with the frame.** EIP-3529 caps the refund at a
    %% fraction of the *transaction's* gas used, and `Intrinsic` is the part of it
    %% the frame cannot see -- it starts at `gasLimit - Intrinsic` and the 21,000
    %% belongs to the transaction. Without this the cap's base is the frame's own
    %% consumption and the node under-refunds by `intrinsic / 5` whenever the cap
    %% binds. It is passed as an argument rather than left in the Env because it is
    %% not a fact about the block or the environment: it is a quantity this
    %% transaction has already been charged, and the only function that knows it is
    %% the one that charged it.
    %% **EIP-7702's step-7 refund goes in as the frame's *starting* refund**, not as
    %% an adjustment afterwards. The EIP says "add ... to the **global refund
    %% counter**", and this frame's counter is the only global counter there is: the
    %% frame's own `SSTORE` refunds accumulate on top of it and EIP-3529's cap -- now
    %% taken over the transaction's gas used -- applies to the **sum**. Charging it
    %% after the frame returned would add to a figure the cap has already trimmed,
    %% which is the mistake `v1.62` declined to make and `v1.65` made unnecessary.
    case run_frame(Code, Msg, StateAuth, Env, EvmGas, Intrinsic, AuthRefund) of
        {error, {unpriced, What}} ->
            {error, {unpriced, What}};
        {Result, Output, GasLeft, StateRun, Logs} ->
        %% Gas charged is what the transaction was given minus what it returned. An
        %% exceptional halt returns nothing, so it is charged its whole limit.
        GasCharged0 = case Result of
                          error -> GasLimitTx;
                          _ -> GasLimitTx - GasLeft
                      end,
        %% EIP-7623: the total is floored at `21000 + 10 * tokens_in_calldata', where a
        %% token is a zero calldata byte or a quarter of a non-zero one. Everything else
        %% in the EIP's `max' is what `GasCharged0' already is -- the intrinsic plus the
        %% execution, with the refund already netted off, because `GasLeft' carries it --
        %% so the whole rule is this one `max'.
        %%
        %% It is Prague, and before Prague the floor is 0 and this is a no-op. The
        %% `max' is also why the `error' arm needs no special case: a frame that consumed
        %% its whole allowance is charged its whole allowance, which is already at or
        %% above the floor because validation refuses a limit below it.
        GasCharged = max(GasCharged0, eth_fork_schedule:calldata_floor(fork(Block), Data)),
        %% The floor is a **charge**, not an accounting entry, and this is the half that is
        %% easy to miss. `settle_gas/7' settles the sender by refunding the unused
        %% allowance against the price `buy_gas/4' charged, so the sender's net is
        %% `GasCharged0 * price' whatever `GasCharged' is set to afterwards. The first
        %% version of this fix therefore reported a `gasUsed' of 21,010 -- the floor --
        %% while the sender was still billed 21,009 and the coinbase was paid a tip on
        %% 21,010. `gasUsed' is a receipt field, so the block would have carried a number
        %% the sender was not charged, and the base fee would have been burned on gas
        %% nobody paid for.
        State1 = settle_gas(deploy(StateRun, Result, Output, Target, IsCreate),
                            Block, Sender, GasLeft, GasCharged, EffectiveGasPrice,
                            base_fee_of(BaseFee), GasCharged - GasCharged0),
        Cumulative = Block#block.gas_used + GasCharged,
        Index = length(Block#block.receipts),
        Block1 = Block#block{
            receipts = Block#block.receipts ++ [make_receipt(Tx, Result, GasCharged,
                                                              Cumulative, Logs, Index)],
            logs = Block#block.logs ++ Logs,
            gas_used = Cumulative
        },
        {Block1, State1}
    end.

%% The effects a transaction has on state that are not the EVM's own execution.
%%
%% The order is the one the yellow paper and geth both use, and it is not
%% arbitrary: the gas is bought *before* execution so that a transaction which
%% cannot pay for its own limit is rejected rather than run and left owing, and
%% the nonce is incremented *before* execution so a contract cannot re-enter the
%% sender with the same nonce.
%%
%% The upfront cost is charged at the sender's ceiling (maxFeePerGas, or
%% gasPrice for a legacy transaction) while the refund below is at the effective
%% price, so the difference is the miner/validator's tip plus the portion of the
%% cap that was never needed. That is why an over-paying 1559 sender is not
%% refunded the cap.
begin_transaction(State, Sender, Target, Value, GasLimit, IsCreate,
                  EffectivePrice, BlobFee) ->
    S1 = buy_gas(State, Sender, GasLimit, EffectivePrice),
    %% EIP-4844: "The actual `blob_fee' as calculated via `calc_blob_fee' is
    %% deducted from the sender balance before transaction execution and burned,
    %% and is not refunded in case of transaction failure." So it is bought here,
    %% next to the gas, and **no arm of `settle_gas/9' returns it** -- not on
    %% success, not on a revert, not on an exceptional halt.
    S2 = buy_blob_gas(S1, Sender, BlobFee),
    S3 = eth_state:set_nonce(S2, Sender, eth_state:nonce(S2, Sender) + 1),
    case IsCreate of
        true -> S3;
        false -> transfer(S3, Sender, Target, Value)
    end.

%% EIP-4844's `calc_blob_fee(header, tx)':
%%
%%     def calc_blob_fee(header, tx) -> int:
%%         return get_total_blob_gas(tx) * get_base_fee_per_blob_gas(header)
%%
%%     def get_total_blob_gas(tx) -> int:
%%         return GAS_PER_BLOB * len(tx.blob_versioned_hashes)
%%
%%     def get_base_fee_per_blob_gas(header) -> int:
%%         return fake_exponential(
%%             MIN_BASE_FEE_PER_BLOB_GAS,
%%             header.excess_blob_gas,
%%             BLOB_BASE_FEE_UPDATE_FRACTION
%%         )
%%
%% The header argument is **this block's own** `excess_blob_gas', not its parent's.
%% That is what the EIP's own text says, and it is also the only reading that makes
%% the two consumers agree: the excess carried *into* a block is
%% `calc_excess_blob_gas(parent)' = `parent.excess + parent.blob_gas_used - TARGET',
%% so `blob_gas_price/1' on the block's own field answers the price of this
%% block's blobs. Passing the parent's pair instead -- `eth_fork_schedule:
%% blob_base_fee/2' -- would price the parent's blobs a second time, off by one
%% block.
%%
%% ## This was absent, and the corpus found it as the largest single divergence.
%%
%% `eth_fork_schedule:blob_gas_price/1' and `blob_base_fee/2' were correct and
%% had exactly two consumers: `eth_call.erl:409' (the `BLOBBASEFEE' opcode's
%% environment) and `eth_tx.erl:775' (the `maxFeePerBlobGas' admission floor). The
%% *settlement* path -- this module -- had no reference to blob gas pricing at
%% all. The node computed the right price, checked the transaction against it, and
%% then never charged it, so every blob transaction's sender kept
%% `total_blob_gas * price` wei that the chain has already burned.
%%
%% The corpus signature is unusually clean:
%%
%%   * `cancun/eip4844_blobs/test_sufficient_balance_blob_tx' -- 1,152 branches,
%%     and `test_blob_gas_subtraction_tx' -- 256, i.e. **1,408 entries**, all
%%     `state_mismatch' with one diff shape: the sender's balance too high by
%%     exactly `total_blob_gas * price`.
%%   * Every one of those fixtures carries 6 versioned hashes, so
%%     `total_blob_gas` is `6 * 131072` = **786,432**, `env.currentExcessBlobGas`
%%     is `0x0e0000` = 917,504, and `blob_gas_price(917504)` is **1** -- so the
%%     discrepancy is 786,432, which is the whole blob fee and nothing else.
%%
%% That is a *consensus* defect with an economic consequence rather than a
%% conformance figure: a node that does not charge for blobs will accept work
%% every other client pays for, and diverges on the sender's balance in every
%% block containing a blob transaction.
%%
%% It is **not** part of `gasUsed'. The receipt's `gasUsed` is normal gas only,
%% and the base fee burn must not be levied on blob gas, so the charge is a
%% balance movement and nothing here touches the block's `gas_used'.
blob_fee(#block{} = Block, Tx) ->
    case eth_tx:tx_type(Tx) of
        eip4844 ->
            Blobs = length(eth_tx:blob_versioned_hashes(Tx)),
            Blobs * eth_fork_schedule:blob_gas_per_blob()
                * blob_base_fee(Block);
        _ ->
            %% No blobs, no charge. A transaction of any other type has no
            %% `blob_versioned_hashes' field to read, and the EIP prices only blobs.
            0
    end.

%% `get_base_fee_per_blob_gas(header)', as **one** function.
%%
%% EIP-4844 uses this figure in two places that must not come from two
%% derivations: `calc_blob_fee/2' **charges** the sender at it, and
%% `validate_block' **requires** `tx.max_fee_per_blob_gas >= it'. A node that
%% checked against one price and charged another would admit a transaction it
%% then charges more than the sender agreed to, or the reverse. So the price is
%% computed here, once, and `validation_ctx/4' hands *this* value to
%% `eth_tx:check_blobs/2' -- which is why the floor check could fire at all
%% before `v1.56`; nothing was passing it one.
%%
%% Exported because the conformance runner builds a block and must hand the
%% validator the same figure, and re-deriving it in the test would be the
%% second-copy mistake `eth_evm:base_cost/1' was deleted for.
blob_base_fee(#block{excess_blob_gas = Excess}) ->
    eth_fork_schedule:blob_gas_price(Excess).

%% EIP-7702's authorization list, as a state transition.
%%
%% For each `[chain_id, address, nonce, y_parity, r, s]` tuple, in order:
%%
%%   1. the chain id is 0 or this chain's;
%%   2. the nonce is below `2**64 - 1`;
%%   3. the authority is recovered, and `s` is in EIP-2's low form;
%%   4. the authority's code is empty or already a delegation indicator;
%%   5. the authority's nonce equals the tuple's;
%%   6. the code becomes `0xef0100 || address` -- or is **cleared** when `address`
%%      is the zero address, which is the EIP's "restore an EOA" case;
%%   7. the authority's nonce increases by one.
%%
%% **A failure at any step skips that tuple and continues with the next**, and that is
%% the whole of "If any step above fails, immediately stop processing the tuple and
%% continue to the next tuple in the list." It is written as a `try' around the seven
%% steps for exactly that reason: a per-step error would have to decide, at each
%% step, whether to continue -- and the EIP's rule is uniform, so encoding it once as
%% "this tuple either applies entirely or not at all" is both shorter and the shape
%% the specification actually has.
%%
%% ## This was absent entirely.
%%
%% The node priced a type-4 transaction for its authorizations
%% (`eth_tx:set_code_gas/2', 25,000 each) and validated the two *structural* rules
%% (`eth_tx:check_set_code/1': a non-empty list, a non-null destination) -- and then
%% executed it **as though it carried no authorizations at all**, which is what
%% AGENTS.md's open-items table has said for some time. The corpus found it as the
%% largest single shape in the `state_mismatch` cluster: **1,005 nonce and 1,002 code
%% divergences and not one storage write**, on
%% `prague/eip7623_increase_calldata_cost/test_transaction_validity_type_4.json`,
%% whose 84 entries carry type-4 transactions with authorization lists. The signature
%% is exactly a delegation -- 23 bytes of code written, nonce bumped, no storage
%% touched -- and the arithmetic confirms it: those fixtures carry 10 authorizations
%% and the expected post-state has 10 accounts holding
%% `0xef0100000000000000000000000000000000000000NN`, one per tuple, in order.
%% **Returns `{State, Authorities}`**, where `Authorities` is every authority that
%% was **recovered**, whether or not its tuple went on to apply.
%%
%% That is EIP-7702 step 4 -- "Add `authority` to `accessed_addresses`, as defined in
%% EIP-2929" -- and it is the step that makes the *refused* tuples observable. The
%% reference implementation puts `message.accessed_addresses.add(authority)`
%% immediately after recovery and **before** the code and nonce checks, so a tuple
%% that names an authority which then fails step 5 or step 6 still leaves that
%% account warm for the rest of the transaction: its `BALANCE` costs 100 rather than
%% 2,600. Adding it only for tuples that apply would be a cheaper-looking rule that
%% disagrees on exactly the tuples a user gets wrong.
%%
%% So the return value is two things rather than one, and the list is threaded
%% through to the Msg as `auth_authorities' rather than being written into a warm set
%% the EVM has not built yet -- `eth_evm:run/5' seeds that set from the Msg, and a
%% set seeded anywhere else is a set nothing reads.
process_authorizations(State, Tx, Fork) ->
    case eth_tx:tx_type(Tx) of
        eip7702 ->
            {S, A, R} = apply_authorizations(State, eth_tx:authorization_list(Tx), Fork),
            {S, A, R};
        _ ->
            {State, [], 0}
    end.

apply_authorizations(State, [], _Fork) -> {State, [], 0};
apply_authorizations(State, [Tuple | Rest], Fork) ->
    %% Three elements, not two: the status is discarded and the **state is carried
    %% through either way**, because a skipped tuple leaves the state alone rather
    %% than aborting the list. That is the EIP's "immediately stop processing the
    %% tuple and continue to the next tuple", and it is why this is a match and not a
    %% `case' -- a `case' would have two arms that both ignore the third element,
    %% which is a way of writing the same rule twice.
    {_Status, S1, Authority, Refund} = apply_authorization(State, Tuple, Fork),
    {S2, Rest2, Rest3} = apply_authorizations(S1, Rest, Fork),
    {S2, warmed(Authority) ++ Rest2, Refund + Rest3}.

%% One address, or none. `undefined' is what a tuple that failed *before* recovery
%% carries, and it must not reach the warm map: `initial_access/3' filters the list
%% to 20-byte binaries, so a stray atom would be dropped there -- but a list that
%% mixes addresses and an atom is a list whose meaning depends on a reader three
%% modules away knowing that. Better to be a list of addresses here.
warmed(undefined) -> [];
warmed(Addr) -> [Addr].

%% `{ok, State, Authority}' when the tuple applied, `{skipped, State, Authority}'
%% when it did not, and an `Authority' **whenever recovery succeeded** -- which is
%% the whole of step 4, and the reason this function is not written as a `try'.
%%
%% **It used to be a `try`, and that was a real defect.** The EIP's rule is "if any
%% step above fails, immediately stop processing the tuple and continue to the next
%% tuple", which a `try`/`catch` around the seven steps expresses in one line -- and
%% steps 5 and 6 were signalled by `true = (...)', so a *refused* tuple raised a
%% `badmatch' and landed in the `catch'.
%%
%% **A `catch` clause cannot see the variables bound in the `try` body.** So
%% `Authority' -- bound by step 3, and the answer step 4 needs -- was gone for
%% exactly the tuples that were refused, and `apply_authorizations/3' received
%% `undefined'. The visible effect was that only *applied* tuples warmed anything,
%% which is the tidier-looking rule and the wrong one: it disagrees on precisely the
%% tuples a user gets wrong. It was found by a test asserting the 2,500 gap on a
%% `BALANCE' of a refused authority, and the two arms first came back **identical**
%% at 48,605 -- the cold figure twice.
%%
%% So the steps are written out. Three predicates, then an action, and the authority
%% is in scope throughout.
apply_authorization(State, [ChainId, Address, Nonce | _Sig], Fork) ->
    %% The **whole** tuple goes to `authorization_authority/1', which re-reads `y_parity',
    %% `r' and `s' from it: the signing preimage is over all three, so passing only the
    %% first three would recover a different account. Passing three of six was the
    %% first version of this line and it would have failed every tuple in the corpus
    %% with a `function_clause' naming neither the tuple nor the field.
    Tuple = [ChainId, Address, Nonce | _Sig],
    %% No step here is fork-gated, and that is not an oversight: a type-4
    %% transaction cannot be valid before Prague -- `eth_fork_schedule:
    %% tx_type_available/2' refuses the type at an earlier fork -- so this function
    %% is unreachable for a pre-Prague block. `Fork' is carried for a future
    %% fork-gated step rather than omitted and re-added at every call site.
    case before_recovery(ChainId, Nonce) of
        false ->
            {skipped, State, undefined, 0};
        true ->
            case eth_tx:authorization_authority(Tuple) of
                error ->
                    {skipped, State, undefined, 0};
                {ok, Authority} ->
                    %% **Step 4 has happened.** Everything from here on may refuse
                    %% the tuple, and the authority is warm either way.
                    case applicable(State, Authority, Nonce) of
                        false ->
                            {skipped, State, Authority, 0};
                        true ->
                            %% **Step 7, and it is read BEFORE the code is written and
                            %% the nonce bumped.** "Add `PER_EMPTY_ACCOUNT_COST -
                            %% PER_AUTH_BASE_COST` gas to the global refund counter
                            %% **if `authority` is not empty**" -- and `set_delegation/4`
                            %% increments the nonce, which *makes* the account non-empty
                            %% by definition. Reading it afterwards would refund every
                            %% delegation by every account, including the ones the EIP
                            %% specifically exempts, and the difference is the whole
                            %% rule: delegating yourself costs half what delegating a
                            %% fresh account does.
                            Refund = case eth_state:exists(State, Authority) of
                                         true -> eth_fork_schedule:set_code_refund(Fork);
                                         false -> 0
                                     end,
                            {ok, set_delegation(State, Authority, Address, Nonce),
                             Authority, Refund}
                    end
            end
    end;
apply_authorization(State, _Malformed, _Fork) ->
    {skipped, State, undefined, 0}.

%% Steps 1 and 2, before an account is named. A failure here has no authority to
%% warm, because nothing was recovered: the tuple named no account at all.
%% **One expression, parenthesised.** Written as two lines with a comma between
%% them and `andalso' starting the second, the first line is a complete statement
%% and `andalso' is a syntax error -- which the compiler reports as "`andalso'",
%% with no hint that the comma was the problem and no note of the *first* line,
%% which is where the reading error was. AGENTS.md §5 lists `band` binding tighter
%% than `-'; this is the same class of mistake with a comma, and the symptom is the
%% same: a message about the token you can see rather than the structure you cannot.
before_recovery(ChainId, Nonce) ->
    (ChainId =:= 0 orelse ChainId =:= eth_fork_schedule:chain_id())
        andalso Nonce < ((1 bsl 64) - 1).

%% Steps 5 and 6. `false' here refuses the tuple **and keeps the authority warm**.
applicable(State, Authority, Nonce) ->
    Code = eth_state:code(State, Authority),
    %% Step 5: "Verify the code of `authority' is empty or already delegated." An
    %% authority with *real* code is skipped, so a delegation can never overwrite a
    %% contract -- and that is also why this agrees with the node's EIP-3607 check:
    %% an account that is neither an EOA nor delegated is not a delegation target
    %% either.
    (Code =:= <<>> orelse eth_tx:is_delegation_indicator(Code))
        andalso eth_state:nonce(State, Authority) =:= Nonce.

%% Steps 6 and 7. Delegating to the zero address **clears** the code, restoring the
%% account to a plain EOA; writing `0xef0100 || 0x00..00' instead would leave a
%% delegation pointing at nothing, which the EIP's rationale explicitly wants to be
%% expressible.
set_delegation(State, Authority, Address, Nonce) ->
    S1 = case Address of
             <<0:160>> -> eth_state:set_code(State, Authority, <<>>);
             _ -> eth_state:set_code(State, Authority,
                                     eth_tx:delegation_indicator(Address))
         end,
    eth_state:set_nonce(S1, Authority, Nonce + 1).

%% The blob fee is a straight debit with no arm on any path that could undo it.
%% It is spelled as its own function rather than folded into `buy_gas/5' so that
%% the one-way-ness is visible: there is no `settle_blob_gas' anywhere in this
%% module, and a grep for it is the check that a refund has not been added.
buy_blob_gas(State, _Sender, 0) -> State;
buy_blob_gas(State, Sender, BlobFee) ->
    eth_state:set_balance(State, Sender, eth_state:balance(State, Sender) - BlobFee).

%% Install the code a creation returned. Only a successful frame deploys: a
%% reverted or failed init code leaves nothing behind at the new address, which
%% is why the account is not pre-created above -- there is then nothing to undo.
%%
%% EIP-161: the new account's nonce is 1, never 0. That is what distinguishes a
%% contract account from an address that has merely been touched, and it is
%% checked by the state trie, so getting it wrong changes the root.
deploy(State, ok, Output, Address, true) when byte_size(Output) =< 24576 ->
    S1 = eth_state:set_code(State, Address, Output),
    S2 = eth_state:set_nonce(S1, Address, 1),
    eth_state:mark_created(S2, Address);
deploy(State, ok, Output, Address, true) ->
    %% EIP-170: the deployed code is over the size limit. The frame still
    %% succeeded, so the gas is spent, but nothing is deployed and the account
    %% does not survive.
    _ = Output,
    eth_state:drop_if_empty(State, Address);
deploy(State, _Result, _Output, _Address, _IsCreate) ->
    State.

%% Charged at the sender's ceiling, not the effective price: the client is
%% committing to the cap and only the difference comes back.
%% **Charge at the effective price, not at the ceiling.** EIP-1559's reference
%% implementation says:
%%
%%     signer.balance -= transaction.gas_limit * effective_gas_price
%%     ...
%%     signer.balance += gas_refund * effective_gas_price
%%
%% so the net is `gas_used * effective_gas_price` -- the cap appears nowhere in the
%% charge. This charged `gasLimit * maxFeePerGas` and `settle_gas/8' refunded at the
%% effective price, which left an overpaying sender charged an extra
%%
%%     (gas_limit - gas_used) * (max_fee_per_gas - effective_gas_price)
%%
%% **and that term is zero whenever `max_fee == base_fee + max_priority`**, which is
%% what every test in this repository set. The case that separates them --
%% `max_fee > base_fee + max_priority`, a sender deliberately overpaying its cap so the
%% base fee can rise without a second transaction -- was the one nobody wrote, and it
%% is the case EIP-1559 exists for.
%%
%% The ceiling is not lost: it is what the sender must be *able* to pay, and
%% `eth_tx:fee_ceiling_ok/4' still checks that against `gasLimit * maxFeePerGas`, which
%% is a validity rule and stays where the EIP puts it. The two were conflated into one
%% number used for both jobs, and only the charge was wrong.
buy_gas(State, Sender, GasLimit, EffectivePrice) ->
    Debit = GasLimit * EffectivePrice,
    eth_state:set_balance(State, Sender, eth_state:balance(State, Sender) - Debit).

transfer(State, From, To, Value) ->
    S1 = eth_state:set_balance(State, From, eth_state:balance(State, From) - Value),
    S2 = eth_state:set_balance(S1, To, eth_state:balance(S1, To) + Value),
    %% EIP-161: a recipient touched by a zero-value transfer is a no-op. A plain
    %% self-send is also a no-op, because the two balance writes cancel and the
    %% account would otherwise be re-created.
    case {Value, From =:= To} of
        {0, _} -> eth_state:drop_if_empty(S2, To);
        {_, true} -> State;
        _ -> S2
    end.

%% Return the unused gas to the sender at the effective price and pay the tip to
%% the coinbase. The two are different amounts on purpose: the sender gets
%% effective price, the coinbase gets effective price minus base fee, and the
%% base fee portion is burned.
%% `FloorExtra' is the amount by which EIP-7623's floor raised the charge above what
%% the frame actually consumed. It comes off the sender, because the floor is a
%% minimum the transaction must pay: it is not a refund to anyone and not a tip, so
%% it reaches the coinbase only through the tip on the larger `GasCharged'.
settle_gas(State, Block, Sender, GasLeft, GasCharged, EffectivePrice, BaseFee,
           FloorExtra) ->
    Miner = Block#block.miner,
    Tip = max(0, EffectivePrice - BaseFee),
    S1 = eth_state:set_balance(State, Sender,
                               eth_state:balance(State, Sender)
                               + GasLeft * EffectivePrice
                               - FloorExtra * EffectivePrice),
    S2 = eth_state:set_balance(S1, Miner,
                               eth_state:balance(S1, Miner) + GasCharged * Tip),
    %% The coinbase is "touched" by receiving a payment even if the payment is
    %% zero, and an account touched but left empty must not survive (EIP-161).
    case GasCharged * Tip of
        0 -> eth_state:drop_if_empty(S2, Miner);
        _ -> S2
    end.

%% CREATE's address: keccak256(rlp([sender, nonce]))[12:]. Deterministic, so
%% nobody has to be trusted to publish it and nobody can be front-run into
%% another account's address.
create_address(Sender, Nonce) ->
    Encoded = eth_rlp:encode([Sender, Nonce]),
    binary:part(eth_keccak:hash(Encoded), 12, 20).

%% The execution environment, in the shape eth_evm reads it: flat atom keys.
%% BLOCKHASH needs a state view to resolve the requested block, so the state is
%% carried alongside rather than looked up again by the opcode.
block_env(Block = #block{number = Number, timestamp = Ts, miner = Miner,
                         gas_limit = GL, base_fee_per_gas = BaseFee,
                         mix_hash = Mix}, State) ->
    #{number => Number,
      timestamp => Ts,
      %% eth_evm:run/5 requires the fork. It is resolved from the block's own
      %% number and timestamp, which is the only pair the fork schedule takes,
      %% so a payload validated against pre-merge rules is executed under
      %% pre-merge rules -- including refusing the instructions those rules do
      %% not have.
      fork => fork(Block),
      coinbase => Miner,
      prevrandao => Mix,
      gas_limit => GL,
      base_fee => base_fee_of(BaseFee),
      chain_id => eth_fork_schedule:chain_id(),
      state => State}.

base_fee_of(undefined) -> 0;
base_fee_of(BaseFee) when is_integer(BaseFee) -> BaseFee;
base_fee_of(_) -> 0.

%% cumulative_gas_used is by definition the gas of every transaction up to and
%% including this one, so it is threaded as a running total rather than recorded
%% per receipt; gasUsed is this transaction's own share. logsBloom is the bloom
%% over *this* receipt's logs -- the block's own bloom is the OR of all of them,
%% so stamping an empty bloom here would make every receipt claim its logs were
%% unfilterable, and a node building receipts from these would answer a
%% filterBloom query wrongly for every block it produced.
make_receipt(Tx, Result, GasUsed, Cumulative, Logs, Index) ->
    Status = case Result of
        ok -> 1;
        revert -> 0;
        error -> 0
    end,
    #{
        <<"status">> => Status,
        <<"gasUsed">> => GasUsed,
        <<"cumulative_gas_used">> => Cumulative,
        <<"logs_bloom">> => eth_bloom:add_logs(eth_bloom:new(), Logs),
        <<"logs">> => Logs,
        <<"type">> => maps:get(<<"type">>, Tx, <<"0x0">>),
        <<"transactionHash">> => maps:get(<<"hash">>, Tx, <<>>),
        <<"transactionIndex">> => Index
    }.

%% ---------------------------------------------------------------------------
%% Engine API payloads
%% ---------------------------------------------------------------------------
%%
%% from_json/1 above decodes a JSON-RPC *block*, which is a different object from
%% an ExecutionPayload. The payload names the height `blockNumber', the fee
%% recipient `feeRecipient' and the mix hash `prevRandao', and it carries its
%% transactions as wire bytes rather than as decoded objects. It also carries no
%% nonce, no sha3Uncles and no difficulty, because after the Merge the first two
%% are fixed constants and the third is zero -- so those come from new/2, where
%% they are the right values rather than placeholders.
%%
%% Unlike from_json/1 this does not default a missing field to something
%% plausible. A payload is a complete object: a consensus client has no reason to
%% omit a field from it, and a field invented here would be hashed into a block
%% hash this node then checked as correct -- a plausible value, silently wrong,
%% which is the failure mode this codebase keeps refusing to ship. So the V1 field
%% set is required, and only the later V2/V3 additions are optional.
from_payload(Payload) ->
    case decode_payload(Payload) of
        {ok, Block, _Wire} -> {ok, Block};
        {error, Reason} -> {error, Reason}
    end.

%% The payload's own `blockHash' is a commitment to its header, and the
%% specification requires it to be validated -- in all cases, including while
%% syncing. That check needs the two roots the payload asserts but does not
%% carry: the transactions root is a trie over the transaction list the payload
%% *does* carry, and the withdrawals root likewise. Both are recomputed here from
%% those lists rather than read from anywhere, so the hash check also ties the
%% block hash to the body.
%%
%% Which header fields are in the encoding depends on which the payload carries,
%% and the answer is not a guess:
%%
%%   Paris     16 fields
%%   Shanghai  17 -- EIP-4895 appended withdrawalsRoot
%%   Cancun    20 -- EIP-4844 appended blobGasUsed and excessBlobGas, and
%%                    EIP-4788 appended parentBeaconBlockRoot
%%
%% EIP-4788 is the one that is easy to get wrong: `parentBeaconBlockRoot' reads
%% like a system-call input rather than a header field, and it is both. The EIP
%% says "execution clients MUST extend the header schema with an additional
%% field: the `parent_beacon_block_root'", and then gives the resulting header
%% RLP with it last. Omitting it produces a header that is 33 bytes short and a
%% block hash no client reproduces.
%%
%% `requestsHash' (EIP-7685) is *not* a header field: it is committed through the
%% beacon-roots contract by EIP-7251, so a Prague header still has 20 fields.
payload_block_hash(Payload) ->
    case decode_payload(Payload) of
        {error, Reason} ->
            {error, Reason};
        {ok, Block, Wire} ->
            case payload_header_fork(Payload) of
                {error, Reason} ->
                    {error, Reason};
                {ok, Fork} ->
                    case payload_roots(Payload, Wire) of
                        {error, Reason} -> {error, Reason};
                        {ok, Roots} ->
                            case payload_header_rlp(Block, Roots, Fork) of
                                {error, Reason2} -> {error, Reason2};
                                Encoded -> {ok, eth_keccak:hash(Encoded)}
                            end
                    end
            end
    end.

%% The forks this encoder distinguishes, which is not the same list as the
%% schedule's: it needs only the header shape, and only the three shapes the
%% specification has ever described.
payload_header_fork(Payload) ->
    BlobUsed = pget(Payload, <<"blobGasUsed">>),
    BlobExcess = pget(Payload, <<"excessBlobGas">>),
    Withdrawals = pget(Payload, <<"withdrawals">>),
    case {BlobUsed, BlobExcess, Withdrawals} of
        {undefined, undefined, undefined} ->
            {ok, paris};
        {undefined, undefined, _} ->
            {ok, shanghai};
        %% EIP-4844 appends both blob fields together, so one without the other
        %% is not a header this node knows how to spell. Guessing which half is
        %% missing would produce a block hash that looks computable and is not.
        {Used, Excess, _} when Used =/= undefined, Excess =/= undefined ->
            case pget(Payload, <<"parentBeaconBlockRoot">>) of
                undefined -> {error, missing_parent_beacon_block_root};
                _ -> {ok, cancun}
            end;
        {Used, Excess, _} ->
            {error, {partial_blob_fields, Used, Excess}}
    end.

payload_roots(Payload, Wire) ->
    case blob_quantities(Payload) of
        {error, Reason} ->
            {error, Reason};
        {ok, BlobGasUsed, ExcessBlobGas} ->
            {ok, #{transactions_root => tx_root_of_wire(Wire),
                   withdrawals_root => withdrawals_root_of(Payload),
                   blob_gas_used => BlobGasUsed,
                   excess_blob_gas => ExcessBlobGas}}
    end.

withdrawals_root_of(Payload) ->
    case pget(Payload, <<"withdrawals">>) of
        undefined -> undefined;
        {ok, Ws} -> eth_fork_schedule:withdrawals_root(withdrawals_from_json(Ws))
    end.

%% These are quantities, and they have to be *decoded*.
%%
%% This used to pass the JSON value straight through, so `"0x0"' reached the RLP
%% encoder as a three-byte string and was encoded as three bytes of ASCII where a
%% single 0x80 belongs. The header was then 6 bytes longer than the header the
%% network hashed, and the block hash was wrong for every Cancun block. It is the
%% same mistake the optional-field setter made, which is what made it worth
%% fixing in both places at once: the hash path and the block path had to agree,
%% and they did not.
%%
%% An unparseable quantity is an error rather than a zero. Defaulting a quantity
%% this node could not read to 0 would move a gas boundary, which is precisely the
%% kind of plausible-but-wrong value this module exists to avoid producing.
blob_quantities(Payload) ->
    case decoded_quantity(Payload, <<"blobGasUsed">>, 0) of
        {error, Reason} -> {error, Reason};
        {ok, BlobGasUsed} ->
            case decoded_quantity(Payload, <<"excessBlobGas">>, 0) of
                {error, Reason2} -> {error, Reason2};
                {ok, ExcessBlobGas} -> {ok, BlobGasUsed, ExcessBlobGas}
            end
    end.

decoded_quantity(Payload, Key, Default) ->
    case pget(Payload, Key) of
        undefined ->
            {ok, Default};
        {ok, Value} ->
            case payload_quantity(Value) of
                {ok, Decoded} -> {ok, Decoded};
                {error, _} -> {error, {bad_quantity, Key}}
            end
    end.

%% The 16 fields of Paris, then the two Shanghai and Cancun each appended.
payload_header_rlp(#block{parent_hash = PH, miner = Miner, sha3_uncles = SU,
                          state_root = SR, receipts_root = RR,
                          logs_bloom = Bloom, difficulty = Diff, number = N,
                          gas_limit = GL, gas_used = GU, timestamp = Ts,
                          extra_data = Extra, mix_hash = Mix, nonce = Nonce,
                          base_fee_per_gas = BF} = Block, Roots, Fork) ->
    Base = [PH, SU, Miner, SR, maps:get(transactions_root, Roots), RR, Bloom,
            Diff, N, GL, GU, Ts, Extra, Mix, Nonce,
            case BF of undefined -> 0; B -> B end],
    case Fork of
        paris ->
            eth_rlp:encode(Base);
        shanghai ->
            eth_rlp:encode(Base ++ [maps:get(withdrawals_root, Roots)]);
        cancun ->
            eth_rlp:encode(Base ++ [maps:get(withdrawals_root, Roots),
                                   maps:get(blob_gas_used, Roots),
                                   maps:get(excess_blob_gas, Roots),
                                   %% EIP-4788's header field, which is also the
                                   %% value handed to the system call. It has to
                                   %% be the same 32 bytes in both places: a
                                   %% header that commits to one root while the
                                   %% contract records another is a block whose
                                   %% state root nobody can reproduce.
                                   parent_beacon_root(Roots, Block)])
    end.

parent_beacon_root(Roots, #block{parent_beacon_block_root = undefined}) ->
    _ = Roots,
    {error, missing_parent_beacon_block_root};
parent_beacon_root(_Roots, #block{parent_beacon_block_root = Root}) ->
    Root.

%% The transaction trie over wire bytes: key RLP(index) from 0, value the
%% transaction exactly as the payload carried it.
%%
%% Computed from the payload's own bytes rather than by re-encoding the decoded
%% transactions. Re-encoding is a round trip through the codec, and a codec that
%% does not round-trip exactly would produce a transactions root that is wrong
%% without being obviously wrong -- and then the block hash built on top of it
%% would be wrong in the same invisible way. The decode path checks the round trip
%% separately, so a codec that cannot reproduce a transaction is reported rather
%% than papered over.
tx_root_of_wire([]) ->
    eth_trie:root([]);
tx_root_of_wire(Wire) ->
    Pairs = [{eth_rlp:encode(I), Bytes}
             || {Bytes, I} <- lists:zip(Wire, lists:seq(0, length(Wire) - 1))],
    eth_trie:root(Pairs).

decode_payload(Payload) when is_map(Payload) ->
    case payload_fields(Payload) of
        {error, Reason} ->
            {error, Reason};
        {ok, Pairs} ->
            case payload_transactions(Payload) of
                {error, Reason} ->
                    {error, Reason};
                {ok, Txs, Wire} ->
                    Block0 = lists:foldl(fun({Field, Value}, Acc) ->
                                                 put_field(Acc, Field, Value)
                                         end, new(<<0:256>>, 0), Pairs),
                    Block1 = put_optional_fields(Block0, Payload),
                    {ok, Block1#block{transactions = Txs}, Wire}
            end
    end;
decode_payload(_Payload) ->
    {error, payload_not_an_object}.

%% The V1 field set, all required.
payload_fields(Payload) ->
    Specs = [{<<"parentHash">>, {data, 32}, parent_hash},
             {<<"feeRecipient">>, {data, 20}, miner},
             {<<"stateRoot">>, {data, 32}, state_root},
             {<<"receiptsRoot">>, {data, 32}, receipts_root},
             {<<"logsBloom">>, {data, 256}, logs_bloom},
             {<<"prevRandao">>, {data, 32}, mix_hash},
             {<<"blockNumber">>, quantity, number},
             {<<"gasLimit">>, quantity, gas_limit},
             {<<"gasUsed">>, quantity, gas_used},
             {<<"timestamp">>, quantity, timestamp},
             {<<"extraData">>, {data, extra}, extra_data},
             {<<"baseFeePerGas">>, quantity, base_fee_per_gas}],
    decode_specs(Payload, Specs, []).

decode_specs(_Payload, [], Acc) ->
    {ok, lists:reverse(Acc)};
decode_specs(Payload, [{Key, Kind, Field} | Rest], Acc) ->
    case pget(Payload, Key) of
        undefined ->
            {error, {missing_field, Key}};
        {ok, Value} ->
            case payload_value(Kind, Value) of
                {ok, Decoded} -> decode_specs(Payload, Rest, [{Field, Decoded} | Acc]);
                {error, Reason} -> {error, {bad_field, Key, Reason}}
            end
    end.

payload_value(quantity, Value) -> payload_quantity(Value);
payload_value({data, Size}, Value) -> payload_data(Value, Size).

%% QUANTITY: a hex string, or an integer for an in-process caller.
payload_quantity(Value) when is_integer(Value), Value >= 0 ->
    {ok, Value};
payload_quantity(Value) when is_binary(Value) ->
    try {ok, eth_hex:decode(Value)} catch _:_ -> {error, not_a_quantity} end;
payload_quantity(_Value) ->
    {error, not_a_quantity}.

%% DATA: a 0x-prefixed hex string, or raw bytes of the required width. The
%% prefixed form is tried first because that is what a decoded JSON object
%% carries; the two are genuinely ambiguous only for a raw 32-byte value that
%% happens to begin with the two bytes "0x", and preferring the wire form is the
%% right way to break that tie.
payload_data(Value, Size) when is_binary(Value) ->
    case hex_data(Value) of
        {ok, Bytes} when Size =:= extra -> {ok, Bytes};
        {ok, Bytes} when byte_size(Bytes) =:= Size -> {ok, Bytes};
        {ok, Bytes} -> {error, {wrong_size, byte_size(Bytes), Size}};
        error when Size =:= extra andalso byte_size(Value) =:= 0 -> {ok, <<>>};
        error when byte_size(Value) =:= Size -> {ok, Value};
        error -> {error, not_data}
    end;
payload_data(_Value, _Size) ->
    {error, not_data}.

%% DATA on the wire: a 0x-prefixed hex string, which is the only form the engine API
%% carries. Exported -- see the note in the export list.
hex_data(<<"0x">>) -> {ok, <<>>};
hex_data(<<"0X", Rest/binary>>) -> from_hex(Rest);
hex_data(<<"0x", Rest/binary>>) -> from_hex(Rest);
hex_data(_) -> error.

from_hex(Hex) ->
    case byte_size(Hex) rem 2 of
        0 ->
            case eth_hex:is_hex(Hex) of
                true -> {ok, binary:decode_hex(Hex)};
                false -> error
            end;
        _ ->
            error
    end.

%% The specification requires every transaction to be at least one byte, in all
%% cases, and a zero-length entry is a malformed payload rather than a
%% transaction. The round-trip check is this node's own addition: it is what
%% stops finalize/1 from recomputing the transactions root from a decode that
%% cannot be reproduced, which would report a spurious mismatch and, worse, make
%% the transactions-root verdict meaningless for that block.
payload_transactions(Payload) ->
    case pget(Payload, <<"transactions">>) of
        undefined ->
            {error, {missing_field, <<"transactions">>}};
        {ok, List} when is_list(List) ->
            decode_transactions(List, 0, [], []);
        {ok, _Other} ->
            {error, {bad_field, <<"transactions">>, not_a_list}}
    end.

decode_transactions([], _Index, Acc, Wire) ->
    {ok, lists:reverse(Acc), lists:reverse(Wire)};
decode_transactions([Item | Rest], Index, Acc, Wire) ->
    case hex_data(Item) of
        {ok, <<>>} ->
            {error, {zero_length_transaction, Index}};
        {ok, Bytes} ->
            case eth_tx:from_rlp(Bytes) of
                {ok, Tx} ->
                    case re_encodes(Tx, Bytes) of
                        true ->
                            decode_transactions(Rest, Index + 1, [Tx | Acc],
                                                [Bytes | Wire]);
                        false ->
                            {error, {transaction_not_re_encodable, Index}}
                    end;
                {error, Reason} ->
                    {error, {invalid_transaction, Index, Reason}}
            end;
        error ->
            {error, {malformed_transaction, Index, not_data}}
    end.

re_encodes(Tx, Bytes) ->
    case eth_tx:to_rlp(Tx) of
        {ok, Bytes} -> true;
        {ok, _Other} -> false;
        {error, _} -> false
    end.

%% The V2/V3 additions, absent on a Paris payload.
put_optional_fields(Block, Payload) ->
    Block1 = case pget(Payload, <<"withdrawals">>) of
        undefined -> Block;
        {ok, Ws} when is_list(Ws) ->
            Block#block{withdrawals = withdrawals_from_json(Ws)};
        {ok, _Other} ->
            Block
    end,
    Block2 = set_quantity_field(blob_gas_used, pget(Payload, <<"blobGasUsed">>), Block1),
    Block3 = set_quantity_field(excess_blob_gas, pget(Payload, <<"excessBlobGas">>), Block2),
    case pget(Payload, <<"parentBeaconBlockRoot">>) of
        undefined -> Block3;
        {ok, Root} ->
            case maybe_word(Root) of
                undefined -> Block3;
                Word -> Block3#block{parent_beacon_block_root = Word}
            end
    end.

%% The value has to be decoded. Storing the raw `"0x0"' leaves a JSON string in a
%% field the header encodes as a number, and RLP encodes a 3-byte binary as a
%% 3-byte string -- so the header would carry three bytes of ASCII where a single
%% 0x80 belongs, and the block hash would not match. `quantity_or_zero/1' in the
%% hash path decodes correctly, so the two paths disagreed, which is the worst
%% way for them to disagree: the hash was right and the block was wrong.
set_quantity_field(_Field, undefined, Block) -> Block;
set_quantity_field(Field, {ok, Value}, Block) ->
    case payload_quantity(Value) of
        {ok, Decoded} when Field =:= blob_gas_used ->
            Block#block{blob_gas_used = Decoded};
        {ok, Decoded} when Field =:= excess_blob_gas ->
            Block#block{excess_blob_gas = Decoded};
        {error, _} ->
            Block
    end.

put_field(B, parent_hash, V) -> B#block{parent_hash = V};
put_field(B, miner, V) -> B#block{miner = V};
put_field(B, state_root, V) -> B#block{state_root = V};
put_field(B, receipts_root, V) -> B#block{receipts_root = V};
put_field(B, logs_bloom, V) -> B#block{logs_bloom = V};
put_field(B, mix_hash, V) -> B#block{mix_hash = V};
put_field(B, number, V) -> B#block{number = V};
put_field(B, gas_limit, V) -> B#block{gas_limit = V};
put_field(B, gas_used, V) -> B#block{gas_used = V};
put_field(B, timestamp, V) -> B#block{timestamp = V};
put_field(B, extra_data, V) -> B#block{extra_data = V};
put_field(B, base_fee_per_gas, V) -> B#block{base_fee_per_gas = V}.

%% Both key forms, for the same reason eth_engine accepts both: a decoded JSON
%% object has binary keys and an in-process caller has no reason to know that.
%% from_json/1 reads binary keys only because its only callers are the upstream
%% sync path and its own tests, both of which hand it a decoded object.
pget(Map, Key) -> pget(Map, Key, undefined).
pget(Map, Key, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> {ok, Value};
        error ->
            case maps:find(binary_to_list(Key), Map) of
                {ok, Value2} -> {ok, Value2};
                error -> Default
            end
    end;
pget(_Map, _Key, Default) ->
    Default.

%% ---------------------------------------------------------------------------
%% Header construction
%% ---------------------------------------------------------------------------

header(#block{parent_hash = ParentHash, number = Number,
               timestamp = Ts, miner = Miner, difficulty = Diff,
               gas_limit = GasLimit, gas_used = GasUsed,
               logs_bloom = Bloom, state_root = StateRoot,
               transactions_root = TxRoot, receipts_root = RecRoot,
               extra_data = Extra, nonce = Nonce, mix_hash = Mix,
               sha3_uncles = SU, base_fee_per_gas = BaseFee,
               blob_gas_used = BG, excess_blob_gas = EG,
               withdrawals_root = WdRoot} = _Block) ->
    #{
        <<"parentHash">> => ParentHash,
        <<"sha3Uncles">> => SU,
        <<"miner">> => Miner,
        <<"stateRoot">> => StateRoot,
        <<"transactionsRoot">> => TxRoot,
        <<"receiptsRoot">> => RecRoot,
        <<"logsBloom">> => Bloom,
        <<"difficulty">> => Diff,
        <<"number">> => Number,
        <<"gasLimit">> => GasLimit,
        <<"gasUsed">> => GasUsed,
        <<"timestamp">> => Ts,
        <<"extraData">> => Extra,
        <<"mixHash">> => Mix,
        <<"nonce">> => Nonce,
        %% A field the header does not have is **absent**, not zero. `0x0' would be a
        %% number this node invented for a field the fork it is describing does not
        %% contain, and `to_payload/1' merges this map straight into the
        %% `ExecutionPayload' that `engine_getPayload' returns -- so a zero here is a
        %% value a consensus client would read as an answer. The three post-London
        %% fields are the ones that can be absent; the rest cannot, so they are
        %% unconditional and the omission is not spread around.
        <<"baseFeePerGas">> => maybe_hex_int(BaseFee),
        <<"withdrawalsRoot">> => WdRoot,
        <<"blobGasUsed">> => BG,
        <<"excessBlobGas">> => EG
    }.

%% `undefined' for a field the header does not carry. JSON-RPC's `0x0' and an absent
%% key are not the same thing and the difference is the whole point: one is a value,
%% the other is an absence, and only one of them is a claim about the chain.
maybe_hex_int(undefined) -> undefined;
maybe_hex_int(V) -> eth_hex:encode_int(V).

%% The withdrawal list, in the JSON-RPC shape from_json/1 accepts.
withdrawal_to_json(#{index := I, validatorIndex := V, address := A,
                      amount := Am}) ->
    #{<<"index">> => eth_hex:encode_int(I),
      <<"validatorIndex">> => eth_hex:encode_int(V),
      <<"address">> => to_hex(A),
      <<"amount">> => eth_hex:encode_int(Am)};
withdrawal_to_json(W) when is_map(W) -> withdrawal_to_json(default_withdrawal(W));
withdrawal_to_json(_) ->
    #{<<"index">> => <<"0x0">>, <<"validatorIndex">> => <<"0x0">>,
      <<"address">> => to_hex(<<0:160>>), <<"amount">> => <<"0x0">>}.

default_withdrawal(#{address := A, amount := Am} = W) ->
    #{index => maps:get(index, W, 0),
      validatorIndex => maps:get(validatorIndex, W, 0),
      address => A, amount => Am};
default_withdrawal(_) ->
    #{index => 0, validatorIndex => 0, address => <<0:160>>, amount => 0}.

%% ---------------------------------------------------------------------------
%% Hashing and serialization
%% ---------------------------------------------------------------------------

%% `to_rlp/1' and `hash/1' used to live here. Both are gone.
%%
%% `to_rlp/1' emitted nineteen header fields unconditionally: the fifteen of Frontier,
%% then `baseFeePerGas', then `withdrawalsRoot', then EIP-4844's two blob fields. So
%% it was wrong at *every* fork -- too many before London, too many before Shanghai,
%% and at Cancun it was short and long at once, because EIP-4788 put
%% `parentBeaconBlockRoot' in the header and this encoder had no term for it while
%% `payload_header_rlp/4' does.
%%
%% The live encoder is `payload_header_rlp/4'. It is selected by the fork the payload
%% itself describes, and it is verified against three real Sepolia blocks: Paris
%% 1450507, Shanghai 3001655 and Cancun 6985356. A second encoder disagreeing with it
%% at every fork is the mistake this repository has already made once and had to
%% delete -- `eth_evm:base_cost/1' was a fork-free duplicate of the gas table, and the
%% two had come to disagree about how they grouped four sets of constants. A header
%% hash is worse than a gas table: a duplicate does not merely drift, it produces a
%% block hash that looks computable and is not.
%%
%% `hash/1' had exactly one caller, which was `to_rlp/1', and that had none --
%% `AGENTS.md' listed them as "unused in `src/`, tests only", which a grep showed was
%% true of neither. Deleting the pair is the fix; a fork-aware rewrite would have
%% been a third encoder to keep in step with the first two.

%% ---------------------------------------------------------------------------
%% Roots
%% ---------------------------------------------------------------------------

%% Transaction trie: key = RLP(index) from 0, value = the transaction's wire
%% encoding. eth_tx:to_rlp/1 yields {ok, Bytes} and returns an error for
%% unsupported types, so an unencodable body falls back to the empty root
%% rather than silently contributing a tuple as a trie value.
tx_root([]) ->
    eth_trie:root([]);
tx_root(Txs) when is_list(Txs) ->
    Pairs = lists:map(
        fun({Tx, I}) ->
            case eth_tx:to_rlp(Tx) of
                {ok, Bytes} -> {eth_rlp:encode(I), Bytes};
                _ -> {eth_rlp:encode(I), <<>>}
            end
        end, lists:zip(Txs, lists:seq(0, length(Txs) - 1))),
    eth_trie:root(Pairs).

%% receipts_root/1 is public API and must return a bare 32-byte root, so the
%% {ok, Root} shape of eth_receipt:receipt_root/1 is unwrapped here.
receipts_root(Receipts) ->
    case eth_receipt:receipt_root(Receipts) of
        {ok, Root} -> Root;
        _ -> eth_trie:root([])
    end.

logs_bloom(Logs) ->
    eth_bloom:add_logs(eth_bloom:new(), Logs).

compute_bloom(Logs) ->
    logs_bloom(Logs).

%% ---------------------------------------------------------------------------
%% State root verification
%% ---------------------------------------------------------------------------
%%
%% see check_state_root/2, called from finalize/1. The previous verify_state_root/2
%% returned ok or {error, state_root_mismatch}, which could not distinguish
%% "the root did not match" from "there was no local state to check against" --
%% and the second case must never be reported as a pass.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

gas_used(Block) ->
    Block#block.gas_used.

%% The block's gas total is the last receipt's cumulative figure, which is the
%% same as summing the per-transaction shares. Cumulative is the safer basis
%% because a receipt fetched from a peer carries only that, so a block whose
%% receipts were never executed locally still totals correctly.
sum_gas_used([]) ->
    0;
sum_gas_used(Receipts) ->
    Last = lists:last(Receipts),
    case maps:get(<<"cumulative_gas_used">>, Last, undefined) of
        undefined -> lists:sum([uint(maps:get(<<"gasUsed">>, R, 0)) || R <- Receipts]);
        Cumulative -> Cumulative
    end.

%% JSON-RPC quantities arrive either as integers or as minimal hex strings, and
%% gas and value arithmetic needs an integer. Using the raw value would compare
%% a binary against a number, which is silently wrong rather than a crash.
uint(V) when is_integer(V) -> V;
uint(V) when is_binary(V) ->
    case eth_hex:is_hex(V) of
        true -> eth_hex:decode(V);
        false -> 0
    end;
uint(_) ->
    0.

%% `uint/1` with the distinction "this field is not on the transaction" preserved.
%% A transaction that has no `maxFeePerGas' is a different thing from one that says
%% `maxFeePerGas = 0x0`, and every caller that needs to tell them apart has to be able
%% to; collapsing the two at the decode is what made a legacy transaction look like a
%% 1559 transaction asking for a zero fee. See `effective_gas_price/4'.
-spec opt_uint(binary() | integer() | undefined) -> integer() | undefined.
opt_uint(undefined) -> undefined;
opt_uint(V) -> uint(V).

to_address(<<"0x", _/binary>> = H) -> hex_to_bin(H);
to_address(A) when is_binary(A), byte_size(A) =:= 20 -> A;
to_address(_) -> <<>>.

to_bytes(<<"0x", _/binary>> = H) -> hex_to_bin(H);
to_bytes(B) when is_binary(B) -> B;
to_bytes(_) -> <<>>.

hex_to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest);
hex_to_bin(B) when is_binary(B) -> B.

%% EIP-1559 effective gas price paid by the sender:
%%   min(maxFeePerGas, baseFeePerGas + maxPriorityFeePerGas)
%% This is the price that is actually charged and that must be reported in the
%% receipt; it is *not* the tip. Legacy transactions use gasPrice directly.
effective_gas_price(GasPrice, MaxPriorityFee, MaxFee, BaseFee) ->
    case {MaxFee, MaxPriorityFee, BaseFee} of
        %% A transaction with neither 1559 field is legacy or 2930, and its price is
        %% `gasPrice' whatever the block's base fee is. This clause is matched on
        %% **absence**, not on a value, and that is the whole point: a 1559 transaction
        %% that asks for a zero fee falls through to the clause below and is answered
        %% `0' -- correctly, and visibly differently from a legacy transaction.
        {undefined, undefined, _} ->
            GasPrice;
        %% A 1559 transaction in a block with no base fee. There is nothing to add, so
        %% the price is the tip, capped by the ceiling. Pre-London this is the only
        %% 1559 case that can arise, and it used to be answered by the `undefined'
        %% clause above -- which returned `gasPrice', i.e. 0 for a typed transaction that
        %% carries no `gasPrice' field at all.
        {MaxFee, MaxPriorityFee, undefined} when is_integer(MaxFee),
                                                 is_integer(MaxPriorityFee) ->
            min(MaxFee, MaxPriorityFee);
        {MaxFee, MaxPriorityFee, BF} when is_integer(MaxFee), is_integer(MaxPriorityFee) ->
            min(MaxFee, BF + MaxPriorityFee);
        _ ->
            GasPrice
    end.

base_fee() ->
    1000000000.

%% A block with no withdrawals commits to the empty trie root, which is what
%% withdrawals_root([]) yields -- same construction as the transactions root,
%% with no entries to insert.
withdrawals_root() ->
    eth_fork_schedule:withdrawals_root([]).

%% ---------------------------------------------------------------------------
%% JSON serialization
%% ---------------------------------------------------------------------------

%% header/1 is the internal form: hashes as raw bytes, numbers as integers.
%% to_json/1 is the JSON-RPC form: everything as hex. Keeping the two distinct
%% matters because from_json/1 parses the JSON form, and a "to_json" that
%% returned raw bytes would not round-trip through its own inverse.
%%
%% It also carries the two fields the header does not have -- the withdrawals
%% list and, from Cancun, the parent beacon block root. Both are inputs to the
%% block's state transition, so dropping them here would mean a block that came
%% off the wire could not be replayed: it would finalize against a state with
%% no withdrawals credited and no beacon root recorded, and agree with nothing.
to_json(#block{withdrawals = Ws, parent_beacon_block_root = PBR} = Block) ->
    maps:merge(
      maps:map(fun
                   (<<"parentHash">>, V) -> to_hex(V);
                   (<<"sha3Uncles">>, V) -> to_hex(V);
                   (<<"miner">>, V) -> to_hex(V);
                   (<<"stateRoot">>, V) -> to_hex(V);
                   (<<"transactionsRoot">>, V) -> to_hex(V);
                   (<<"receiptsRoot">>, V) -> to_hex(V);
                   (<<"logsBloom">>, V) -> to_hex(V);
                   (<<"withdrawalsRoot">>, V) -> to_hex(V);
                   (<<"extraData">>, V) -> to_hex(V);
                   (<<"mixHash">>, V) -> to_hex(V);
                   (<<"nonce">>, V) -> to_hex(V);
                   (<<"difficulty">>, V) -> eth_hex:encode_int(V);
                   (<<"number">>, V) -> eth_hex:encode_int(V);
                   (<<"gasLimit">>, V) -> eth_hex:encode_int(V);
                   (<<"gasUsed">>, V) -> eth_hex:encode_int(V);
                   (<<"timestamp">>, V) -> eth_hex:encode_int(V);
                   (<<"blobGasUsed">>, V) -> eth_hex:encode_int(V);
                   (<<"excessBlobGas">>, V) -> eth_hex:encode_int(V);
                   (_, V) -> V
               end, header(Block)),
      #{
        <<"withdrawals">> => [withdrawal_to_json(W) || W <- Ws],
        <<"parentBeaconBlockRoot">> => case PBR of
            undefined -> undefined;
            _ -> to_hex(PBR)
        end
      }).

%% to_payload/1 is the inverse of from_payload/1, and it did not exist. The
%% decoder was the only half of the payload codec, so `engine_getPayload' had
%% nothing to hand back even once a builder existed: to_json/1 produces *block*
%% JSON, which is a different structure -- it carries `miner', `nonce',
%% `difficulty', `sha3Uncles' and `transactionsRoot', and omits `feeRecipient',
%% `prevRandao', `blockNumber' and `blockHash'. A client destructuring the result
%% of getPayloadV1 for the specification's field names would find none of them.
%%
%% The block hash is computed by payload_block_hash/1 rather than hash/1, and that
%% is deliberate: payload_block_hash/1 is the fork-aware encoder -- it emits 16,
%% 17 or 20 header fields depending on which the payload carries -- and it is the
%% one pinned by the real Sepolia block hashes in eth_block_payload_tests. hash/1
%% goes through to_rlp/1, which includes the Cancun trailing fields
%% unconditionally and so is only correct for Cancun-or-later headers (AGENTS.md
%% section 10, "deliberately not done").
%%
%% `transactions' is emitted as the EIP-2718 wire bytes, because that is what the
%% decoder reads and therefore what the transactions root is computed over. The
%% encoder cannot reconstruct the original bytes from a decoded transaction --
%% a type-3 transaction's `blobVersionedHashes' is not an RPC field at all -- so
%% a transaction this module cannot re-encode is an error here rather than a
%% silently wrong root. {unencodable_transaction, Index} names which one.
to_payload(#block{} = Block) ->
    case encode_transactions(Block) of
        {ok, Txs} ->
            Base = #{<<"parentHash">> => to_hex(Block#block.parent_hash),
                     <<"feeRecipient">> => to_hex(Block#block.miner),
                     <<"stateRoot">> => to_hex(Block#block.state_root),
                     <<"receiptsRoot">> => to_hex(Block#block.receipts_root),
                     <<"logsBloom">> => to_hex(Block#block.logs_bloom),
                     <<"prevRandao">> => to_hex(Block#block.mix_hash),
                     <<"blockNumber">> => eth_hex:encode_int(Block#block.number),
                     <<"gasLimit">> => eth_hex:encode_int(Block#block.gas_limit),
                     <<"gasUsed">> => eth_hex:encode_int(Block#block.gas_used),
                     <<"timestamp">> => eth_hex:encode_int(Block#block.timestamp),
                     <<"extraData">> => to_hex(Block#block.extra_data),
                     <<"transactions">> => Txs,
                     %% Only the post-Paris additions, and only when the block
                     %% carries them. A Paris payload must not grow a `withdrawals'
                     %% key, because the structure check in eth_engine compares the
                     %% exact key set and would answer -32602 to this node's own
                     %% payload -- so the key is added by drop_absent/1 below
                     %% rather than given a placeholder value. A placeholder would
                     %% be present-and-wrong, which is the same failure as the
                     %% defaulted payload field from_payload/1 refuses to invent.
                     <<"__withdrawals__">> => payload_withdrawals(Block)},
            case base_fee_quantity(Block) of
                {ok, FeeHex} ->
                    Base0 = drop_absent(Base#{<<"baseFeePerGas">> => FeeHex}),
                    Base1 = payload_blob_fields(Block, Base0),
                    Base2 = payload_beacon_root(Block, Base1),
                    %% payload_block_hash/1 answers {ok, Hash} | {error, Reason},
                    %% not a bare binary. Wrapping the tagged tuple in data_hex/1
                    %% was the first version's bug, and it is worth writing down
                    %% because the failure is a function_clause on a 66-byte
                    %% binary -- nothing that names the function which got the
                    %% shape wrong.
                    case payload_block_hash(Base2) of
                        {ok, Hash} ->
                            {ok, Base2#{<<"blockHash">> => to_hex(Hash)}};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% `baseFeePerGas' is a required field of ExecutionPayloadV1 and there is no
%% honest value for a pre-London block: emitting `null' would make the payload
%% fail the decoder's own required-field check and fail the structure check in
%% eth_engine (which reads `null' as not provided), and emitting 0 would state a
%% base fee the network never had. So a block without one is an error here, not a
%% number. The Engine API is post-Merge, so this cannot arise on any payload a
%% consensus client would receive -- and if it ever did, refusing is the answer
%% that does not invent a value.
%% Remove the two placeholder keys. A pre-Paris block must not carry a
%% `withdrawals' key at all, and the internal key is renamed rather than deleted
%% so a map that *should* have had one is visibly distinguishable from a map whose
%% withdrawals were dropped.
drop_absent(Map) ->
    Base0 = case maps:get(<<"__withdrawals__">>, Map, absent) of
                {present, Ws} -> Map#{<<"withdrawals">> => Ws};
                absent -> maps:remove(<<"__withdrawals__">>, Map)
            end,
    maps:remove(<<"__withdrawals__">>, Base0).

base_fee_quantity(#block{base_fee_per_gas = undefined}) ->
    {error, {no_base_fee, pre_london}};
base_fee_quantity(#block{base_fee_per_gas = BaseFee})
  when is_integer(BaseFee), BaseFee >= 0 ->
    {ok, eth_hex:encode_int(BaseFee)}.

%% Named for the encoder to keep it distinct from payload_transactions/1 above,
%% which is the *decoder's* reader of a payload map's `transactions' key. Both
%% take one argument and both are about transactions, which is exactly the pair
%% that gets confused for the same function.
encode_transactions(#block{transactions = Txs}) ->
    encode_transactions(Txs, 0, []).

encode_transactions([], _Index, Acc) ->
    {ok, lists:reverse(Acc)};
encode_transactions([Tx | Rest], Index, Acc) ->
    case eth_tx:to_rlp(Tx) of
        {ok, Bytes} ->
            encode_transactions(Rest, Index + 1, [to_hex(Bytes) | Acc]);
        _ ->
            {error, {unencodable_transaction, Index}}
    end.

%% `withdrawals' is present exactly when the block has the list at all. The
%% record's default is `[]', which cannot distinguish "no withdrawals" from "no
%% such field", so the fork decides -- a pre-Shanghai block has no withdrawals
%% field and must not emit one.
%% eth_fork_schedule:at_least/2 is (Fork, Feature) -- "is this fork at least that
%% feature" -- and reading it as (Feature, Fork) compiles, runs, and answers
%% false for every Cancun block, because Shanghai is not at least Cancun. Both
%% arguments are atoms of the same shape, so nothing catches it: the withdrawals
%% key is simply left off, and the block hash that follows is computed over a
%% header missing a field rather than raising.
payload_withdrawals(#block{withdrawals = Ws} = Block) ->
    case eth_fork_schedule:at_least(fork(Block), shanghai) of
        true -> {present, [withdrawal_to_json(W) || W <- Ws]};
        false -> absent
    end.

payload_blob_fields(#block{blob_gas_used = BGU, excess_blob_gas = EBG} = Block,
                     Base) ->
    case eth_fork_schedule:at_least(fork(Block), cancun) of
        true ->
            Base#{<<"blobGasUsed">> => eth_hex:encode_int(BGU),
                  <<"excessBlobGas">> => eth_hex:encode_int(EBG)};
        false ->
            Base
    end.

payload_beacon_root(#block{parent_beacon_block_root = undefined}, Base) ->
    Base;
payload_beacon_root(#block{parent_beacon_block_root = Root}, Base) ->
    Base#{<<"parentBeaconBlockRoot">> => to_hex(Root)}.

%% Hex is emitted lowercase. The chain store indexes blocks by the canonical
%% lowercase hash eth_header produces, and a lookup built from uppercase hex
%% finds nothing -- so this is load-bearing, not a style choice.
to_hex(V) when is_binary(V) ->
    <<"0x", (string:lowercase(binary:encode_hex(V)))/binary>>;
to_hex(V) -> V.
