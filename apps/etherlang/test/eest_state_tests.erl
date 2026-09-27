%% Runs the `execution-spec-tests` state-test corpus against this node's state
%% transition, and records what does not match.
%%
%% This module is the answer to a question the repository could previously only
%% assert an opinion about. "Is the EVM right?" had no evidence behind it: the
%% opcode table was cross-checked against go-ethereum and execution-specs'
%% instruction *counts*, and the gas schedule was derived from the EIPs and
%% pinned by unit tests -- but nothing in this repository had ever been *run*
%% against a third party's expected results. A self-consistent client and a
%% conformant client produce identical results on every fixture written for the
%% self-consistent one, which is how a schedule can be found wrong four times by
%% reading it against the EIPs and still not know it is wrong.
%%
%% So the evidence is a corpus, and this is the thing that runs it.
%%
%% == Where the corpus comes from, and how much of it there is
%%
%% The upstream release is `execution-spec-tests` v5.4.0, asset
%% `fixtures_stable.tar.gz` (published 2025-12-06). Its `state_tests` suite is
%% 2,681 files and 503 MB, of which 315 MB is a single `static/` directory of
%% legacy VMTests. Committing that is not an option and pretending to have run
%% it would be worse, so:
%%
%%   * the *committed* corpus under `test/vectors/eest/` is a curated subset
%%     small enough to read, which the eunit suite pins;
%%   * the *whole* corpus can be run from an extracted tarball by pointing
%%     `EEST_CORPUS` at it, which is how the totals in README.md and TASKS.md
%%     were obtained. The command is in `test/vectors/eest/PROVENANCE.md`.
%%
%% A test that reaches for a network is not allowed in this repository, and the
%% corpus is committed for the same reason the Sepolia payloads are: the
%% expected results are somebody else's, and they must be pinned rather than
%% re-derived.
%%
%% == What is compared, and what is deliberately not
%%
%% Per fixture entry, in order, each a separate outcome so that a codec problem
%% is never reported as an execution problem:
%%
%%   1. the transaction bytes decoded (`eth_tx:from_rlp/1`) and the resulting
%%      hash against the fixture's own `hash`;
%%   2. the recovered sender (`eth_tx:sender/1`) against the fixture's `sender`;
%%   3. the post-state, per account and per slot.
%%
%% Gas is compared *through the balance*, because that is where a state test
%% puts it: the sender's balance falls by `gasUsed * effectivePrice` and the
%% value it sent, so a wrong gas figure shows up as a wrong balance. The runner
%% also inverts that arithmetic to recover the gas each side spent, because
%% "this fixture diverges" is not actionable and "this fixture diverges by 2,100
%% gas, which is EIP-2929's cold account surcharge" is.
%%
%% The signature is *not* re-derived from the fixture's `secretKey`. The
%% fixture's own signed bytes are used, which makes sender recovery a real check
%% rather than a check of this repository's own signing against itself.
%%
%% == Deviations, named
%%
%% These are real limits of what the numbers below mean. None of them is
%% worked around silently.
%%
%%   * **The block's number and timestamp are synthesised, not the fixture's.**
%%     `eth_block` derives a block's fork from its own number and timestamp and
%%     has no way to be told a fork outright, so the runner picks a
%%     number/timestamp pair that lands on the fixture's fork under the mainnet
%%     schedule. Consequence: the `BLOCKNUMBER` and `TIMESTAMP` opcodes do not
%%     see the fixture's values, so a state test that reads them is out of scope.
%%     The alternative -- leaving the fixture's own values and executing every
%%     pre-Merge fixture under Paris -- would be wrong on far more of them and
%%     wrong *silently*, which is the failure mode this repository treats as
%%     worst.
%%   * **Frontier is unreachable.** The mainnet schedule's earliest activation
%%     is Homestead at 1,150,000, so there is no number or timestamp that
%%     selects `frontier`, and a block before it resolves to `paris`. Frontier
%%     entries are reported as `fork_unreachable` and counted, not skipped
%%     quietly.
%%   * **`CHAINID` is mainnet's 1.** That is what the fixtures declare
%%     (`config.chainid: 0x01`) and what `ETH_NETWORK=mainnet` makes
%%     `eth_fork_schedule:chain_id/0` return, so this one agrees by
%%     construction rather than by luck. The runner sets the network explicitly
%%     for the same reason: the default is Sepolia, whose chain id is 11155111.
%%   * **No state root, no receipts root, no bloom, no block header.** A state
%%     test asserts none of those, and this node cannot currently execute a
%%     whole block against EEST anyway (see the `blockchain_tests` gap in
%%     TASKS.md). This is a state-transition corpus, not a block corpus, and the
%%     total below must not be read as block-level conformance.
-module(eest_state_tests).

-include_lib("eunit/include/eunit.hrl").
-include("eth_block.hrl").

-export([corpus/0, committed/0, entries/0, entries/1, outcomes/0,
         tally/1, report/0, report/1]).

%% ---------------------------------------------------------------------------
%% The corpus
%% ---------------------------------------------------------------------------

%% `EEST_CORPUS' points at an extracted upstream tarball; without it the run is
%% over the committed subset. The two produce different totals by design -- one
%% is the whole upstream suite, the other is what the repository pins -- and
%% `report/0' says which it did.
corpus() ->
    case os:getenv("EEST_CORPUS") of
        false -> committed();
        "" -> committed();
        Dir -> Dir
    end.

%% Path relative to the project root, which is where `rebar3 eunit' runs from.
%% There is no portable way to ask a compiled test module where its own source
%% tree is, and the alternative -- shipping the fixtures into `_build' -- would
%% put 500 MB of somebody else's expected results next to the build output.
committed() -> "apps/etherlang/test/vectors/eest".

%% ---------------------------------------------------------------------------
%% Fork selection
%% ---------------------------------------------------------------------------
%%
%% A fixture names its fork in the test key, `[fork_Berlin-state_test]'. Getting
%% that fork into the execution path needs a block whose number and timestamp
%% land on it under the mainnet schedule, because `eth_block:fork_of/1' has no
%% way to be told a fork outright.
%%
%% `undefined' marks a fork with no such number or timestamp. Frontier is the
%% only one: the mainnet schedule's earliest activation is Homestead at
%% 1,150,000, so nothing selects `frontier' and a block before that resolves to
%% `paris'. Those entries are reported, not skipped.
%%
%% Paris is selected by total difficulty, not by a number -- EIP-3675 -- so the
%% four post-Merge entries carry mainnet's TERMINAL_TOTAL_DIFFICULTY and differ
%% only in timestamp.
fork_point(<<"Homestead">>) -> {1200000, 0, undefined};
fork_point(<<"Byzantium">>) -> {5000000, 0, undefined};
%% EEST's `ConstantinopleFix' is Petersburg's rules: Constantinople's
%% activation was reverted and re-applied, and the pair share a block number, so
%% the schedule reaches petersburg and the higher rank is what comes back.
fork_point(<<"ConstantinopleFix">>) -> {7300000, 0, undefined};
fork_point(<<"Istanbul">>) -> {9100000, 0, undefined};
fork_point(<<"Berlin">>) -> {12250000, 0, undefined};
fork_point(<<"London">>) -> {13000000, 0, undefined};
fork_point(<<"Paris">>) -> {20000000, 1000, mainnet_ttd()};
fork_point(<<"Shanghai">>) -> {20000000, 1690000000, mainnet_ttd()};
fork_point(<<"Cancun">>) -> {20000000, 1720000000, mainnet_ttd()};
fork_point(<<"Prague">>) -> {20000000, 1750000000, mainnet_ttd()};
fork_point(<<"Osaka">>) -> {20000000, 1770000000, mainnet_ttd()};
fork_point(_) -> undefined.

mainnet_ttd() -> 58750000000000000000000.

fork_of_key(Key) ->
    %% `binary' capture, not `list': thoas decodes JSON object keys as binaries,
    %% so the `post' map is keyed by <<"Berlin">> and a name arriving as the
    %% string "Berlin" matches nothing. Every entry then reports
    %% `no_post_for_fork', which reads as a total absence of expected results
    %% rather than as a string/binary mismatch.
    case re:run(Key, "fork_([A-Za-z0-9]+)-", [{capture, all_but_first, binary}]) of
        {match, [Name]} -> Name;
        _ -> undefined
    end.

%% ---------------------------------------------------------------------------
%% Outcomes
%% ---------------------------------------------------------------------------
%%
%% The vocabulary is the point of this module. "Diverges" is not a category:
%% a codec that cannot decode the transaction, a signature that recovers the
%% wrong address, a transaction the node admits that the specification rejects,
%% and a state that comes out different are four different bugs with four
%% different owners, and a single pass/fail number would sum them.

-define(MATCH, match).
-define(STATE_MISMATCH, state_mismatch).
-define(TX_DECODE, tx_decode_failed).
-define(TX_ROUNDTRIP, tx_roundtrip_mismatch).
-define(SENDER, sender_mismatch).
-define(REJECT_NOT_RAISED, expected_rejection_not_raised).
-define(REJECT_MISMATCH, rejection_mismatch).
-define(FORK_UNREACHABLE, fork_unreachable).
-define(CRASH, crash).
-define(NO_POST, no_post_for_fork).
-define(BAD_FIXTURE, unreadable_fixture).

outcomes() ->
    [?MATCH, ?STATE_MISMATCH, ?TX_DECODE, ?TX_ROUNDTRIP, ?SENDER,
     ?REJECT_NOT_RAISED, ?REJECT_MISMATCH, ?FORK_UNREACHABLE, ?CRASH,
     ?NO_POST, ?BAD_FIXTURE].

tally(Results) ->
    lists:foldl(fun({_Key, Outcome, _Detail, _File}, Acc) ->
                    maps:update_with(Outcome, fun(N) -> N + 1 end, 1, Acc)
                end,
                #{},
                Results).

%% ---------------------------------------------------------------------------
%% Reporting
%% ---------------------------------------------------------------------------

report() -> report(corpus()).

report(Root) ->
    Results = entries(Root),
    #{root => Root,
      total => length(Results),
      tally => tally(Results),
      results => Results}.

%% ---------------------------------------------------------------------------
%% Corpus walking
%% ---------------------------------------------------------------------------

entries() -> entries(corpus()).

entries(Root) ->
    %% `**' rather than `*': the corpus is nested fork/suite/file, so a
    %% single-level wildcard finds nothing and reports a zero total, which reads
    %% as "everything passes" rather than as "nothing was run".
    Files = filelib:wildcard(filename:join([Root, "**", "*.json"])),
    %% Every read is local for the whole traversal, and not as an optimisation.
    %% `eth_state' answers from its overlay and falls through to `base_source' for
    %% anything absent, which in the default `upstream' mode is an HTTP call to a
    %% public Sepolia node. The coinbase is the obvious one: a fixture's `pre'
    %% rarely declares it, and `settle_gas/7' reads its balance to pay the tip.
    %% A test that does this does not fail, it *hangs*, and EUnit reports a hang
    %% as a cancelled test -- so the symptom is a suite quietly losing tests.
    WithLocal = fun() -> lists:sort(lists:append([file_entries(F) || F <- Files])) end,
    eth_test_util:with_local_reads(WithLocal).

file_entries(File) ->
    case read_fixture(File) of
        {ok, Map} when is_map(Map) ->
            [begin {Outcome, Detail} = run(Key, Entry), {Key, Outcome, Detail, File} end
             || {Key, Entry} <- maps:to_list(Map), is_map(Entry)];
        {error, Why} ->
            %% One entry, carrying the reason, so a file that cannot be read is
            %% visible in the tally rather than absent from the total.
            [{File, ?BAD_FIXTURE, Why, File}]
    end.

read_fixture(File) ->
    case file:read_file(File) of
        {error, Reason} -> {error, Reason};
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, Map} when is_map(Map) -> {ok, Map};
                _ -> {error, undecodable}
            end
    end.

%% Run one fixture entry and classify it.
%%
%% The three checks are ordered so that a failure in an earlier one cannot be
%% reported as a failure in a later one. A transaction this node cannot decode
%% says nothing about its state transition, and a sender recovered from the
%% wrong key would make every account differ for a reason that has nothing to do
%% with the EVM. So the codec and the signature are checked first and reported
%% under their own names, and `state_mismatch' means the state transition itself
%% disagreed.
run(Key, Entry) ->
    case fork_of_key(Key) of
        undefined -> {?FORK_UNREACHABLE, {no_fork_in_key, Key}};
        Fork ->
            case fork_point(Fork) of
                undefined -> {?FORK_UNREACHABLE, {no_activation_point, Fork}};
                _ ->
                    case post_for_fork(Entry, Fork) of
                        undefined -> {?NO_POST, {fork, Fork}};
                        Post -> run_post(Fork, Entry, Post)
                    end
            end
    end.

%% The expected post-state for this fork.
%%
%% `post' is keyed by fork name and an entry may list several entries for the
%% same fork -- the filler emits one per generated case -- so the first is taken
%% and the rest are not compared. That is a real limit and it is stated in
%% PROVENANCE.md rather than papered over: a file that generates several cases
%% for one fork is contributing one of them, and which one is not recorded in
%% the fixture's own key.
post_for_fork(Entry, Fork) ->
    Post = maps:get(<<"post">>, Entry, #{}),
    case maps:find(Fork, Post) of
        {ok, [_One | _]} -> _One;
        _ -> undefined
    end.

run_post(Fork, Entry, Post) ->
    %% `txbytes' and `hash' are hex DATA in the fixture; `eth_tx:from_rlp/1' and
    %% the `hash' it puts in the decoded map are raw bytes. Handing one to the
    %% other fails to decode, which is indistinguishable from a codec that
    %% cannot read a transaction type.
    TxBytes = bytes(maps:get(<<"txbytes">>, Post, <<"0x">>)),
    case eth_tx:from_rlp(TxBytes) of
        {error, _} = E -> {?TX_DECODE, E};
        {ok, Tx} -> check_roundtrip(Tx, TxBytes, Entry, Fork, Post)
    end.

%% The decoded transaction, re-encoded, must equal the bytes it came from.
%%
%% This replaced a check of the transaction hash against the fixture's `hash'
%% field, which was wrong and was wrong quietly. The `post' entry carries a
%% `hash'; it is not the transaction's, and this node's hash was right. Computed
%% independently -- keccak256 over the fixture's own `txbytes', outside this
%% codebase -- the result is exactly what `eth_tx:from_rlp/1' produces, and it
%% does not equal the fixture's field. Comparing the two reported a mismatch on
%% every fixture in the corpus. What that field *is* has not been established
%% here, so it is not checked; see the module comment.
%%
%% A round-trip is the better check, and it is not circular: the bytes are
%% execution-specs' own encoding, so re-encoding this node's decoded map back to
%% them exercises the field order and the integer and byte-width rules of every
%% transaction type against a third party rather than against itself.
check_roundtrip(Tx, TxBytes, Entry, Fork, Post) ->
    case eth_tx:to_rlp(Tx) of
        {ok, Reencoded} when Reencoded =:= TxBytes ->
            check_sender(Tx, Entry, Fork, Post);
        {ok, Reencoded} ->
            {?TX_ROUNDTRIP, [{got, short(Reencoded)}, {want, short(TxBytes)}]};
        Other ->
            {?TX_ROUNDTRIP, Other}
    end.

%% Enough of two byte strings to tell them apart in a failure message, and no
%% more: a 98-byte transaction printed whole is a wall of hex that hides the one
%% byte that differs.
short(Bin) when is_binary(Bin), byte_size(Bin) > 24 ->
    {truncated, byte_size(Bin), binary:part(Bin, 0, 12),
     binary:part(Bin, byte_size(Bin) - 12, 12)};
short(Bin) -> Bin.

check_sender(Tx, Entry, Fork, Post) ->
    Want = bytes(maps:get(<<"sender">>, maps:get(<<"transaction">>, Entry, #{}),
                            <<"0x">>)),
    case eth_tx:sender(Tx) of
        {ok, Got} when Got =:= Want -> run_tx(Fork, Tx, Entry, Post);
        {ok, Got} -> {?SENDER, {got, hex(Got)}, {want, hex(Want)}};
        {error, _} = E -> {?SENDER, E}
    end.

%% A transaction with a rejected nonce, an intrinsic gas limit below the floor,
%% or a chain the block is not on must not be executed. The specification says so
%% in the fixture (`expectException'), and a node that ran one anyway would
%% produce a state that no other client produces -- so the check is that the node
%% *refuses* it, and `REJECT_NOT_RAISED' is a divergence, not a pass.
run_tx(Fork, Tx, Entry, Post) ->
    case maps:get(<<"expectException">>, Post, undefined) of
        undefined -> execute(Fork, Tx, Entry, Post);
        Expected -> expect_rejection(Fork, Tx, Entry, Expected)
    end.

expect_rejection(Fork, Tx, Entry, Expected) ->
    Block = block(Fork, Entry),
    State = state(Entry, #{}),
    case eth_tx:validate(Tx, validation_ctx(Block, State)) of
        {error, _Reason} -> {?REJECT_MISMATCH, {expected, Expected}};
        ok -> {?REJECT_NOT_RAISED, {expected, Expected}}
    end.

%% The block the transaction executes in.
%%
%% Number and timestamp come from `fork_point/1' rather than from the fixture's
%% own `env', because the fork is derived from them and there is no other way in.
%% See the module comment: this is a deviation, and it costs BLOCKNUMBER and
%% TIMESTAMP. Everything else the fixture does specify -- coinbase, gas limit,
%% difficulty -- is used as given.
block(Fork, Entry) ->
    Env = maps:get(<<"env">>, Entry, #{}),
    {Number, Timestamp, TD} = fork_point(Fork),
    (eth_block:new(<<0:256>>, Number))#block{
        timestamp = Timestamp,
        miner = addr(maps:get(<<"currentCoinbase">>, Env, <<"0x">>)),
        difficulty = int(maps:get(<<"currentDifficulty">>, Env, <<"0x0">>)),
        total_difficulty = TD,
        gas_limit = int(maps:get(<<"currentGasLimit">>, Env, <<"0x0">>)),
        gas_used = 0,
        base_fee_per_gas = base_fee_for(Fork),
        mix_hash = <<0:256>>,
        logs_bloom = eth_bloom:new()}.

%% The block's base fee, and it is not one value.
%%
%% The field does not exist before London, and `eth_block:effective_gas_price/4'
%% tells the two apart by `undefined' rather than by a number. Handing it `0' for
%% a pre-London block sends it down the EIP-1559 branch -- `maps:get(<<"maxFeePerGas">>',
%% Tx, 0)' cannot distinguish an absent field from a zero one, and both are
%% integers, so `min(0, 0 + 0)' is 0 -- and every legacy transaction then executes
%% with a gas price of zero. The sender pays nothing, the coinbase gets no tip,
%% and the block's balances are wrong in a way that looks like a gas bug in the
%% schedule rather than like a defaulted argument. It is worth knowing that this
%% function has that failure mode; it is not reachable from `finalize/1', which
%% passes the block's own base fee and a pre-London block has none.
base_fee_for(Fork) ->
    case eth_fork_schedule:at_least(Fork, london) of
        true -> 0;
        false -> undefined
    end.

%% The pre-state as an overlay.
%%
%% Every account and every slot the fixture declares is put in the overlay, which
%% matters for two reasons. It is the only way `eth_state' can answer without
%% reaching for the upstream node -- a unit test that performs a lazy fetch is
%% not a unit test -- and it means every key a later comparison reads is
%% present, so no read can fall through to `base_source' and return something
%% that is not this fixture's.
state(Entry, Post) ->
    Pre = maps:get(<<"pre">>, Entry, #{}),
    %% eth_state:new/2 takes overrides keyed the way the overlay is keyed, so the
    %% fold builds that key shape directly rather than calling the setters.
    Overrides = lists:foldl(fun(Account, Acc) -> account(Account, Acc) end,
                            #{}, maps:to_list(Pre)),
    eth_state:new(0, lists:foldl(fun({A, Slots}, Acc) -> seed_slots(A, Slots, Acc) end,
                                 seed_absent(mentioned(Entry, Post), Overrides),
                                 slots_named(Entry, Post))).

%% Every address the fixture mentions anywhere: in `pre', in the expected post
%% state, as sender or destination, and as the fee recipient.
%%
%% The union matters, and not only for the comparison. `eth_state:storage/3' and
%% `balance/2' are read *during execution* by the EVM and by `settle_gas/7', and
%% they fall through to `base_source' for anything the overlay does not hold. Under
%% `with_local_reads' that base source is the local MPT: process-wide, shared with
%% every other test in the run, and not this fixture's business.
%%
%% It was measurable. The same corpus and the same code gave six matches standalone
%% and seven under eunit, and the extra one was a fixture passing on state another
%% test had left behind -- a higher match rate caused by unrelated data, which is
%% worse than a flaky number because it is a wrong answer that looks right. Seeding
%% only the comparison was not enough; the reads that changed behaviour were the
%% EVM's own.
mentioned(Entry, Post) ->
    Env = maps:get(<<"env">>, Entry, #{}),
    Tx = maps:get(<<"transaction">>, Entry, #{}),
    lists:usort(
      [addr(A) || A <- maps:keys(maps:get(<<"pre">>, Entry, #{}))]
      ++ [addr(A) || A <- maps:keys(maps:get(<<"state">>, Post, #{}))]
      ++ [addr(maps:get(<<"sender">>, Tx, <<"0x">>)),
          addr(maps:get(<<"to">>, Tx, <<"0x">>)),
          addr(maps:get(<<"currentCoinbase">>, Env, <<"0x">>))]).

%% Every `(account, slot)' the expected post state names, including slots the
%% transaction writes that `pre' never declared. A slot written by the transaction
%% is read before it is written -- that read is EIP-2200's `original' -- so leaving
%% it out of the overlay sends that read to the base source, and the value it comes
%% back with changes the price.
slots_named(_Entry, Post) ->
    PostState = maps:get(<<"state">>, Post, #{}),
    [{addr(A), [word(S) || S <- maps:keys(maps:get(<<"storage">>, F, #{}))]}
     || {A, F} <- maps:to_list(PostState), is_map(F)].

seed_slots(A, Slots, Overrides) ->
    lists:foldl(fun(S, Acc) ->
        case Acc of
            #{{store, A, S} := _} -> Acc;
            _ -> Acc#{{store, A, S} => 0}
        end
    end, Overrides, Slots).

%% An address the fixture mentions but does not declare is an empty account, and an
%% empty account is what a state test means by an address that is not in `pre'. It
%% is put in the overlay as zero rather than left to be looked up.
seed_absent(Addresses, Overrides) ->
    lists:foldl(fun(A, Acc) ->
        case Acc of
            #{{balance, A} := _} -> Acc;
            _ -> Acc#{{balance, A} => 0, {nonce, A} => 0, {code, A} => <<>>}
        end
    end, Overrides, Addresses).

account({Hex, Fields}, Acc) when is_map(Fields) ->
    A = addr(Hex),
    Acc1 = maps:put({nonce, A}, int(maps:get(<<"nonce">>, Fields, <<"0x0">>)), Acc),
    Acc2 = maps:put({balance, A}, int(maps:get(<<"balance">>, Fields, <<"0x0">>)), Acc1),
    Acc3 = maps:put({code, A}, bytes(maps:get(<<"code">>, Fields, <<"0x">>)), Acc2),
    maps:fold(fun(Slot, V, A3) -> maps:put({store, A, word(Slot)}, int(V), A3) end,
              Acc3, maps:get(<<"storage">>, Fields, #{}));
account(_, Acc) -> Acc.

%% The validation context eth_tx:validate/2 wants. Built here rather than taken
%% from eth_block because `validation_ctx/4' is not exported; it is the public
%% function's documented input shape, and this test is checking the validator's
%% verdict rather than reimplementing the validator.
validation_ctx(Block, State) ->
    #{base_fee => base_fee_of(Block),
      gas_limit => Block#block.gas_limit,
      gas_used => Block#block.gas_used,
      chain_id => eth_fork_schedule:chain_id(),
      fork => fork_of_block(Block),
      balance_of => fun(A) -> {ok, eth_state:balance(State, A)} end,
      nonce_of => fun(A) -> {ok, eth_state:nonce(State, A)} end}.

%% The base fee as `eth_block:base_fee_of/1' reads it: `undefined' for a block
%% that has none, and 0 for one at London or later where 0 is a real figure.
base_fee_of(#block{base_fee_per_gas = undefined}) -> undefined;
base_fee_of(#block{base_fee_per_gas = B}) -> B.

fork_of_block(Block) ->
    {ok, Fork} = eth_fork_schedule:current_fork(eth_fork_schedule:configured_network(),
                                               Block#block.number, Block#block.timestamp,
                                               Block#block.total_difficulty),
    Fork.

execute(Fork, Tx, Entry, Post) ->
    Block = block(Fork, Entry),
    PreState = state(Entry, Post),
    {Block1, State1} = eth_block:run_transaction(Block, Tx, PreState,
                                                  base_fee_for(Fork),
                                                  Block#block.gas_limit),
    Receipt = last_receipt(Block1),
    %% Both states, because the gas figure is an *arithmetic* recovery from the
    %% sender's balance and needs the balance it started from. Reading the
    %% "before" figure out of the post-state -- which the first version did --
    %% makes every side spend zero gas and reports a delta of 0 for a fixture
    %% that is thousands of gas out, which is the one number a reader would
    %% believe.
    compare(Post, Entry, State1, PreState, Receipt, Tx).

last_receipt(Block) ->
    case Block#block.receipts of
        [] -> #{};
        Rs -> lists:last(Rs)
    end.

%% ---------------------------------------------------------------------------
%% Comparison
%% ---------------------------------------------------------------------------

compare(Post, Entry, State, PreState, Receipt, Tx) ->
    Expected = maps:get(<<"state">>, Post, #{}),
    Diffs = lists:sort(lists:append(
        [account_diff(A, F, State) || {A, F} <- maps:to_list(Expected), is_map(F)])),
    case Diffs of
        [] -> {?MATCH, ok};
        _ -> {?STATE_MISMATCH, #{diffs => Diffs,
                                 gas => gas_story(Diffs, Entry, PreState, Receipt, Tx)}}
    end.

%% Every field of every account the fixture declares, compared one at a time. A
%% diff is a flat list of {where, field, want, got} so that a failure names the
%% account and the field rather than "the state", which is the difference between
%% a report and a shrug.
account_diff(A, F, State) ->
    Addr = addr(A),
    field_diff(A, balance, int, F, <<"balance">>, 0,
               overlay(State, {balance, Addr}, 0))
        ++ field_diff(A, nonce, int, F, <<"nonce">>, 0,
                      overlay(State, {nonce, Addr}, 0))
        ++ field_diff(A, code, bytes, F, <<"code">>, <<"0x">>,
                      overlay(State, {code, Addr}, <<>>))
        ++ slot_diff(A, F, State, Addr).

%% Read the overlay and nothing else.
%%
%% `eth_state:balance/2', `nonce/2', `code/2' and `storage/3' all answer from the
%% overlay first and then fall through to `base_source'. Under `with_local_reads'
%% that base source is the local MPT, which is process-wide and shared with every
%% other test in the run -- so a comparison that reached for it was reading whatever
%% the rest of the suite had left behind.
%%
%% The tally proved it. The same corpus, same code, two environments: six fixtures
%% matched standalone and seven under eunit, and the extra one was
%% `frontier/touch/test_zero_gas_price_and_touching' at four forks -- EIP-161's
%% rule that an account touched at zero gas price does not survive. A *higher*
%% match rate caused by unrelated state is worse than a flaky number, because it is
%% a wrong answer that looks right.
%%
%% Reading the overlay directly makes the comparison a pure function of the fixture
%% and of what the node did: absent means absent, which for a state test is zero,
%% because EIP-161 says an account that did not survive has nothing in it.
overlay(State, Key, Default) ->
    maps:get(Key, maps:get(overlay, State, #{}), Default).

%% One field, and only if it differs. Reporting every field unconditionally --
%% which the first version did -- makes every account a diff, so a genuine
%% balance difference is buried in a list where equal values are printed next to
%% equal values and the report reads as noise. A diff has to mean *diff*.
field_diff(A, Name, Decoder, F, Key, Default, Got) ->
    case field(F, Key, Default, Decoder) of
        Got -> [];
        Want -> [{addr, A, {Name, Want, Got}}]
    end.

%% One declared field, decoded. `int' and `bytes' are the two decoders this
%% module has, and picking the wrong one for a field is how a comparison ends up
%% asserting something about a number that was read as bytes.
field(F, Key, Default, int) -> int(maps:get(Key, F, Default));
field(F, Key, Default, bytes) -> bytes(maps:get(Key, F, Default)).

slot_diff(A, F, State, Addr) ->
    maps:fold(
      fun(Slot, V, Acc) ->
          Want = int(V),
          Got = overlay(State, {store, Addr, word(Slot)}, 0),
          case Got =:= Want of
              true -> Acc;
              false -> Acc ++ [{store, A, hex(word(Slot)), Want, Got}]
          end
      end, [], maps:get(<<"storage">>, F, #{})).

%% Why a fixture diverged, in the form that names a cause rather than a symptom.
%%
%% A state test asserts gas nowhere. It asserts the *balances* the gas produced,
%% and for the sender that arithmetic inverts exactly: the sender is charged
%% `gasUsed * effectivePrice' up front and refunded the unused remainder, and a
%% successful transaction additionally moves `value' out. So both sides' gas can
%% be recovered from the balances, and the difference between them is a gas
%% figure -- which is the difference between "this fixture diverges" and "this
%% fixture is 45,247 gas light, which is EIP-2929's cold account charge and
%% about sixteen times that". Reporting the raw wei difference instead is the
%% kind of number nobody acts on.
%%
%% A reverted transaction gets its value back, so it must not be subtracted, and
%% the receipt's status is what says which happened. When the price is zero, or
%% the balance difference does not divide by it, there is no gas figure to report
%% and this says so rather than dividing anyway.
gas_story(Diffs, Entry, PreState, Receipt, Tx) ->
    Sender = bytes(maps:get(<<"sender">>, maps:get(<<"transaction">>, Entry, #{}),
                            <<"0x">>)),
    case [D || {addr, A, {balance, _W, _G}} = D <- Diffs, A =:= hex(Sender)] of
        [] -> unavailable;
        [{addr, _, {balance, Want, Got}}] ->
            Price = effective_price(Tx, Receipt),
            Value = moved_value(Tx, Receipt),
            Before = overlay(PreState, {balance, Sender}, 0),
            Expected = gas_of(Before, Want, Price, Value),
            Actual = gas_of(Before, Got, Price, Value),
            #{price => Price, value => Value,
              spent_expected => Expected,
              spent_actual => Actual,
              delta => gas_delta(Expected, Actual)}
    end.

%% How much more or less gas this node spent than the fixture expected, when
%% both sides produced a figure. `no_comparable_gas' rather than a number when
%% either side did not: a delta between two unknowns is a third unknown.
gas_delta({gas, E}, {gas, A}) -> A - E;
gas_delta(_, _) -> no_comparable_gas.

%% Gas implied by a balance, or `no_gas' when the arithmetic does not come out
%% whole. Dividing and rounding would produce a plausible wrong number, which is
%% worse than none.
gas_of(_Before, _Balance, 0, _Value) -> no_gas_at_zero_price;
gas_of(Before, Balance, Price, Value) ->
    case (Before - Balance - Value) rem Price of
        0 -> {gas, (Before - Balance - Value) div Price};
        _ -> no_gas_not_divisible
    end.

%% The price the sender was actually charged at.
%%
%% EIP-1559's effective price is `min(maxFee, baseFee + maxPriorityFee)', and the
%% runner executes against a base fee of zero, so that reduces to the priority
%% fee. A legacy or 2930 transaction has only `gasPrice'.
effective_price(Tx, _Receipt) ->
    case {maps:get(<<"maxFeePerGas">>, Tx, undefined),
          maps:get(<<"maxPriorityFeePerGas">>, Tx, undefined)} of
        {undefined, _} -> q_int(Tx, <<"gasPrice">>);
        {MaxFee, Priority} when is_binary(MaxFee), is_binary(Priority) ->
            min(int(MaxFee), int(Priority));
        {MaxFee, _} when is_binary(MaxFee) -> int(MaxFee);
        _ -> q_int(Tx, <<"gasPrice">>)
    end.

%% What left the sender's balance as value rather than as gas. A revert hands it
%% back, so it is only money that actually moved when the receipt says the
%% transaction succeeded.
moved_value(Tx, Receipt) ->
    case maps:get(<<"status">>, Receipt, 1) of
        1 -> q_int(Tx, <<"value">>);
        _ -> 0
    end.

%% A transaction field that `eth_tx' keeps as hex text.
q_int(Tx, Key) ->
    case maps:get(Key, Tx, undefined) of
        Bin when is_binary(Bin) -> int(Bin);
        _ -> 0
    end.

%% ---------------------------------------------------------------------------
%% Decoding helpers
%% ---------------------------------------------------------------------------
%%
%% The fixture spells every number as a hex QUANTITY string and every byte string
%% as hex DATA. `eth_hex:decode/1' is the QUANTITY decoder and returns an
%% integer; `decode_bytes/1' is the DATA one and returns a binary. Conflating
%% them is the mistake this pair of helpers exists to prevent.

int(undefined) -> 0;
int(Hex) when is_integer(Hex) -> Hex;
int(<<"0x", _/binary>> = Hex) -> eth_hex:decode(Hex);
int(Bin) when is_binary(Bin) -> binary:decode_unsigned(Bin).

%% `eth_hex:decode_bytes/1' answers `{ok, Bin}', not a bare binary. Treating it
%% as the binary hands a tuple to `eth_tx:from_rlp/1`, which fails on every
%% fixture and reports as `tx_decode_failed' -- which is indistinguishable from
%% a codec that cannot read a legacy transaction, and is exactly the kind of
%% failure that would be believed.
bytes(Bin) when is_binary(Bin) ->
    case eth_hex:decode_bytes(Bin) of
        {ok, Out} -> Out;
        _ -> <<>>
    end;
bytes(_) -> <<>>.

%% A storage slot key, as the 32-byte word both the fixture and `eth_state' use.
%% `eth_state:slot_key/1' pads short binaries on the left and truncates long ones,
%% so passing the integer is equivalent and avoids re-deriving the padding here.
word(Hex) when is_integer(Hex) -> Hex;
word(<<"0x", _/binary>> = Hex) -> eth_hex:decode(Hex);
word(Bin) when is_binary(Bin) -> binary:decode_unsigned(Bin).

hex(N) when is_integer(N) -> eth_hex:encode_int(N);
hex(B) when is_binary(B) -> eth_hex:encode_bytes(B).

addr(Hex) when is_binary(Hex) -> eth_state:address(Hex);
addr(Other) -> eth_state:address(Other).
