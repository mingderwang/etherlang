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
          hash/1,
          add_transaction/2,
          declare_state_root/2,
          finalize/1,
          from_json/1,
          to_json/1,
          tx_root/1,
          receipts_root/1,
          logs_bloom/1,
          gas_used/1,
          base_fee/0,
          withdrawals_root/0 ]).

-record(block, {
    parent_hash :: binary(),
    number :: integer(),
    timestamp :: integer(),
    miner :: binary(),
    difficulty :: integer(),
    gas_limit :: integer(),
    gas_used :: integer(),
    transactions :: [map()],
    receipts :: [map()],
    logs :: [map()],
    logs_bloom :: binary(),
    state_root :: binary(),
    receipts_root :: binary(),
    transactions_root :: binary(),
    base_fee_per_gas :: integer() | undefined,
    blob_gas_used :: integer(),
    excess_blob_gas :: integer(),
    withdrawals :: [map()],
    withdrawals_root :: binary(),
    extra_data :: binary(),
    nonce :: binary(),
    mix_hash :: binary(),
    sha3_uncles :: binary()
}).

-define(MAX_GAS, 30000000).
-define(EMPTY_ROOT, <<16#56, 16#e8, 16#1f, 16#17, 16#1b, 16#cc, 16#55, 16#a6,
                       16#ff, 16#83, 16#45, 16#e6, 16#92, 16#c0, 16#f8, 16#6e,
                       16#5b, 16#48, 16#e0, 16#1b, 16#99, 16#6c, 16#ad, 16#c0,
                       16#01, 16#62, 16#2f, 16#b5, 16#e3, 16#63, 16#b4, 16#21>>).

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
        extra_data = <<>>,
        nonce = <<0:192>>,
        mix_hash = <<0:256>>,
        sha3_uncles = ?EMPTY_ROOT
    }.

%% new/3 attaches a base fee, which new/2 cannot know on its own.
new(ParentHash, Number, BaseFee) ->
    (new(ParentHash, Number))#block{base_fee_per_gas = BaseFee}.

add_transaction(Block, Tx) ->
    Block#block{transactions = Block#block.transactions ++ [Tx]}.

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
        gas_limit = uint(maps:get(<<"gasLimit">>, Map, ?MAX_GAS)),
        extra_data = to_bytes(maps:get(<<"extraData">>, Map, <<>>)),
        nonce = to_bytes(maps:get(<<"nonce">>, Map, <<0:192>>)),
        mix_hash = to_bytes(maps:get(<<"mixHash">>, Map, <<0:256>>))
    },
    Block2 = maybe_declare(Block1, maps:get(<<"stateRoot">>, Map, undefined)),
    Block3 = maybe_declare(Block2, maps:get(<<"transactionsRoot">>, Map, undefined),
                           transactions_root),
    maybe_declare(Block3, maps:get(<<"receiptsRoot">>, Map, undefined),
                  receipts_root).

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
%%   * gas_used, logs_bloom, transactions_root and receipts_root all derive
%%     from the block's own contents, so recomputing them is meaningful and a
%%     declared value that disagrees is a real error.
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
%%   Verification :: #{state_root := {verified, Root} | {unverified, Reason},
%%                    transactions_root := Root,
%%                    receipts_root := Root,
%%                    gas_used := Gas}
%% A caller that must not accept an unverifiable block reads this map rather
%% than trusting the block's state_root field.
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
            %% silently wrong. The content-derived commitments are still
            %% meaningful, so they are still recomputed.
            {ok, commitments(Block), #{state_root => {unverified, state_not_local}}};
        true ->
            Previous = eth_state:base_source(),
            ok = eth_state:set_base_source(mpt),
            try
                State = eth_state:new(Block#block.parent_hash, #{}),
                {Executed, State1} = execute_transactions(Block, Txs, State, BaseFee,
                                                           GasLimit),
                case eth_state:commit(State1) of
                    ok ->
                        Root = eth_mpt:state_root(),
                        Verification = #{state_root =>
                                             check_state_root(Executed#block.state_root,
                                                              Root),
                                         transactions_root =>
                                             tx_root(Executed#block.transactions),
                                         receipts_root =>
                                             receipts_root(Executed#block.receipts),
                                         gas_used => Executed#block.gas_used},
                        {ok, commitments(Executed, Root), Verification};
                    {error, Reason} ->
                        {ok, commitments(Executed),
                         #{state_root => {unverified, {commit_failed, Reason}},
                           transactions_root => tx_root(Executed#block.transactions),
                           receipts_root => receipts_root(Executed#block.receipts),
                           gas_used => Executed#block.gas_used}}
                end
            after
                _ = eth_state:set_base_source(Previous)
            end
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

%% Returns the block and the post-execution state. The state is threaded rather
%% than discarded: without it every transaction in a block sees the pre-block
%% state, so the transactions in a block cannot build on each other at all.
execute_transactions(Block, [], State, _BF, _GL) ->
    {Block, State};
execute_transactions(#block{number = Number, timestamp = Ts,
                     miner = Miner, base_fee_per_gas = BaseFee,
                     gas_limit = GL} = Block,
                 [Tx | Rest], State, _BF, GL) ->
    GasLimitTx = uint(maps:get(<<"gas">>, Tx, GL)),
    Value = uint(maps:get(<<"value">>, Tx, 0)),
    To = to_address(maps:get(<<"to">>, Tx, <<>>)),
    Data = to_bytes(maps:get(<<"input">>, Tx, <<>>)),
    Nonce = uint(maps:get(<<"nonce">>, Tx, 0)),
    MaxPriorityFee = uint(maps:get(<<"maxPriorityFeePerGas">>, Tx, 0)),
    MaxFee = uint(maps:get(<<"maxFeePerGas">>, Tx, 0)),
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
    Msg = #{
        <<"sender">> => Sender,
        <<"to">> => To,
        <<"value">> => Value,
        <<"gas">> => GasLimitTx,
        <<"gasPrice">> => EffectiveGasPrice,
        <<"nonce">> => Nonce,
        <<"input">> => Data
    },
    %% Code is read through the same state view the EVM executes against.
    %% Fetching it from a separate store would let a call run against code that
    %% the state it runs in says does not exist.
    Code = eth_state:code(State, To),
    Env = #{
        block => #{
            <<"number">> => Number,
            <<"timestamp">> => Ts,
            <<"gasLimit">> => GL,
            <<"baseFeePerGas">> => BaseFee
        },
        coinbase => Miner
    },
    {Result, GasLeft, State1, Logs} =
        try eth_evm:run(Code, Msg, State, Env, GasLimitTx) of
            {ok, _Output, GL0, St0, L0} -> {ok, GL0, St0, L0};
            {revert, _Output, GL1, St1, L1} -> {revert, GL1, St1, L1};
            {error, _Reason, St2, L2} -> {error, 0, St2, L2}
        catch
            %% An EVM crash is an exceptional halt, which consumes the whole
            %% gas limit and discards the frame. It is not the same as a revert,
            %% which is a deliberate failure the caller can observe in the
            %% return data, and must not be recorded as one.
            _:_ -> {error, 0, State, []}
        end,
    %% Gas charged is what the transaction was given minus what it returned. An
    %% exceptional halt returns nothing, so it is charged its whole limit.
    GasCharged = case Result of
                     error -> GasLimitTx;
                     _ -> GasLimitTx - GasLeft
                 end,
    Cumulative = Block#block.gas_used + GasCharged,
    Block1 = Block#block{
        receipts = Block#block.receipts ++ [make_receipt(Tx, Result, GasCharged,
                                                          Cumulative, Logs)],
        logs = Block#block.logs ++ Logs,
        gas_used = Cumulative
    },
    execute_transactions(Block1, Rest, State1, BaseFee, GL).

%% cumulative_gas_used is by definition the gas of every transaction up to and
%% including this one, so it is threaded as a running total rather than recorded
%% per receipt; gasUsed is this transaction's own share.
make_receipt(Tx, Result, GasUsed, Cumulative, Logs) ->
    Status = case Result of
        ok -> 1;
        revert -> 0;
        error -> 0
    end,
    #{
        <<"status">> => Status,
        <<"gasUsed">> => GasUsed,
        <<"cumulative_gas_used">> => Cumulative,
        <<"logs_bloom">> => eth_bloom:new(),
        <<"logs">> => Logs,
        <<"type">> => maps:get(<<"type">>, Tx, <<"0x0">>),
        <<"transactionHash">> => maps:get(<<"hash">>, Tx, <<>>),
        <<"transactionIndex">> => 0
    }.

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
        <<"baseFeePerGas">> => case BaseFee of
            undefined -> <<"0x0">>;
            BF -> eth_hex:encode_int(BF)
        end,
        <<"withdrawalsRoot">> => WdRoot,
        <<"blobGasUsed">> => BG,
        <<"excessBlobGas">> => EG
    }.

%% ---------------------------------------------------------------------------
%% Hashing and serialization
%% ---------------------------------------------------------------------------

hash(Block) ->
    eth_keccak:hash(to_rlp(Block)).

to_rlp(#block{parent_hash = PH, number = N, timestamp = Ts,
               miner = Miner, difficulty = Diff, gas_limit = GL,
               gas_used = GU, logs_bloom = Bloom, state_root = SR,
               transactions_root = TR, receipts_root = RR,
               extra_data = Extra, nonce = Nonce, mix_hash = Mix,
               sha3_uncles = SU, base_fee_per_gas = BaseFee,
               blob_gas_used = BG, excess_blob_gas = EG,
               withdrawals_root = WR} = _Block) ->
    BaseFeeInt = case BaseFee of
        undefined -> 0;
        BF -> BF
    end,
    eth_rlp:encode([PH, SU, Miner, SR, TR, RR, Bloom, Diff, N, GL, GU,
                    Ts, Extra, Mix, Nonce, BaseFeeInt, WR, BG, EG]).

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
    case BaseFee of
        undefined -> GasPrice;
        BF when is_integer(MaxFee), is_integer(MaxPriorityFee) ->
            min(MaxFee, BF + MaxPriorityFee);
        _ -> GasPrice
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
to_json(#block{} = Block) ->
    Json = header(Block),
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
             end, Json).

%% Hex is emitted lowercase. The chain store indexes blocks by the canonical
%% lowercase hash eth_header produces, and a lookup built from uppercase hex
%% finds nothing -- so this is load-bearing, not a style choice.
to_hex(V) when is_binary(V) ->
    <<"0x", (string:lowercase(binary:encode_hex(V)))/binary>>;
to_hex(V) -> V.
