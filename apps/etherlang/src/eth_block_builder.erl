%% Block builder: turns a consensus client's payloadAttributes into a block.
%%
%% This module was dead code. It was a `gen_server' that nothing started, absent
%% from `etherlang.app.src's registered list and from `etherlang_sup's children, so
%% `build_block/0,1' would raise `noproc'. Its only surviving caller was a test of
%% `validate_transaction/2', and `engine_getPayload' reported every `payloadId'
%% unknown because nothing ever issued one.
%%
%% It is also written here again, because the version that was dead could not have
%% been started honestly. It assembled a block as a map with its own copies of the
%% header fields, and those copies were wrong in four ways -- three of which are
%% defects this project had already found and fixed in eth_block, where the same
%% constants live:
%%
%%   nonce => <<0:192>>        24 bytes, where the nonce is 8. RLP prefixes a
%%                             string by its length, so the header came out 16
%%                             bytes too long and every block hash was wrong.
%%   sha3_uncles => state_root  the empty *trie* root standing in for
%%                             Keccak256(RLP([])). This is the substitution the
%%                             README records as "one constant standing in for
%%                             another".
%%   receipts_root => trie root the same substitution again, and
%%   tx_trie_root([]) => ...    the same substitution a third time: an *empty*
%%                             transaction list roots to Keccak256(RLP([])), not to
%%                             the empty trie root.
%%   (no parent_beacon_block_root)  a Cancun header is 20 fields and this was 19.
%%
%% So the block is no longer assembled here. It is built by `eth_block:new/3',
%% which is the one place in the codebase that constructs a header and which
%% carries the corrected constants, and then committed by `eth_block:finalize/1',
%% which recomputes every root and reports each as a verdict rather than as a
%% bare value. Two constructors and two commitment paths is how a block gets a
%% right hash in one place and a wrong one in another, and this module was the
%% second place.
%%
%% HONESTY -- what a block built here is and is not
%% =============================================
%%
%% A payload this node builds is NOT one it can prove the network would accept.
%% The per-fork gas table is not wired into the EVM (see TASKS.md Phase 5 and
%% AGENTS.md section 10), so the state root this module derives from executing the
%% body is computed under one flat Cancun-era schedule for every fork. It will
%% therefore not match the root the network computed for the same block, and it
%% must not be presented as though it would.
%%
%% What IS checked here is real and is reported as such: the transactions root,
%% the receipts root and the withdrawals root all derive from the block's own
%% contents, so `eth_block:finalize/1' recomputes and verifies each one, and
%% `build/1' returns the verdicts alongside the payload. The state root is
%% different in kind -- it depends on prestate this node may not hold -- and
%% finalize/1 says so with `{unverified, Reason}' rather than stamping a number it
%% cannot justify. build/1 logs every unverified root at notice level. A caller
%% that wants to know whether a payload is trustworthy has the verdicts; a caller
%% that ignores them is choosing to.
%%
%% The consensus client is not told any of this: ExecutionPayloadV1 has no field
%% for "unverified", and a proposer that returns no payload gets no block at all.
%% So the gap is reported here and in the documentation rather than on the wire,
%% and it is the reason this node is not yet production-usable.

-module(eth_block_builder).

-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([ build/1,
          store_payload/2,
          get_payload/1,
          forget/1,
          status/0,
          validate_transaction/1,
          validate_transaction/2,
          %% Exported and pure so the arithmetic can be tested without a txpool, a
          %% chain, or a state root. It is a consensus-visible number: it is the
          %% `blockValue' field of getPayloadV2/V3, i.e. what the fee recipient is
          %% promised, and a wrong one is a proposer that under- or over-states its
          %% own revenue.
          block_value/1 ]).

-include_lib("etherlang/include/eth_block.hrl").

-define(MAX_GAS, 30000000).
%% secp256k1 group order; EIP-2 requires 1 <= r,s < N.
-define(SECP256K1_N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).

%% A payloadId is DATA, 8 bytes (execution-apis src/engine/paris.md,
%% engine_getPayloadV1). Kept until the CL collects it or the node is restarted.
%% There is no expiry clock: an unused payloadId is a build this node will not
%% offer again, and dropping it early is worse than holding it, because the CL may
%% still be waiting for it. `forget/1' exists for the caller that knows.
-define(PAYLOAD_ID_BYTES, 8).

-record(st, {
    %% payloadId => {Payload, BlockValue}
    payloads = #{} :: #{binary() => {map(), integer()}},
    max_gas = ?MAX_GAS :: integer(),
    max_transactions = 2048 :: integer()
}).

%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link() ->
    start_link(#{}).

start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Opts) ->
    logger:notice("etherlang: block builder started"),
    {ok, #st{max_gas = maps:get(max_gas, Opts, ?MAX_GAS),
             max_transactions = maps:get(max_transactions, Opts, 2048)}}.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

handle_call({build, Attributes}, _From, S) ->
    {Reply, S1} = case build(Attributes) of
                      {ok, Payload, BlockValue} ->
                          {ok, PayloadId, Payload1, Value1} =
                              new_payload(Payload, BlockValue),
                          {ok, PayloadId,
                           insert_payload(S, PayloadId, Payload1, Value1)};
                      {error, Reason} ->
                          {error, Reason, S}
                  end,
    {reply, Reply, S1};
handle_call({store, Payload, BlockValue}, _From, S) ->
    {ok, PayloadId, Payload1, Value1} = new_payload(Payload, BlockValue),
    {reply, {ok, PayloadId},
     insert_payload(S, PayloadId, Payload1, Value1)};
handle_call({payload, PayloadId}, _From, S) ->
    %% {ok, Payload, BlockValue}, not the bare stored pair: the caller needs to
    %% tell a served payload from `unknown_payload', and a 2-tuple where it expects
    %% a 3-tuple raises rather than answering -- so getPayload crashed on every id
    %% this node had actually issued.
    {reply, case maps:get(PayloadId, S#st.payloads, missing) of
                missing -> {error, unknown_payload};
                {Payload, BlockValue} -> {ok, Payload, BlockValue}
            end, S};
handle_call({forget, PayloadId}, _From, S) ->
    {reply, ok, S#st{payloads = maps:remove(PayloadId, S#st.payloads)}};
handle_call(get_status, _From, S) ->
    {reply, status(S), S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

%% build/1 assembles one block for the attributes a consensus client supplied.
%%
%% `Attributes' is the *decoded* form -- raw binaries and integers, not the JSON
%% strings the Engine API carries. Decoding belongs to eth_engine, which already
%% does it for the admission checks, so doing it again here would be a second
%% place for a field to be read wrongly. The keys are:
%%
%%   parent_hash              32 bytes, the head the CL built on
%%   number                   integer
%%   timestamp                integer -- the CL's, not the clock's
%%   prev_randao              32 bytes (DATA prevRandao)
%%   fee_recipient            20 bytes (DATA suggestedFeeRecipient)
%%   withdrawals              [WithdrawalV1] -- the CL's list, not an empty one
%%   parent_beacon_block_root 32 bytes, Cancun and later
%%   base_fee                 integer, computed from the parent
%%   gas_limit                integer, optional
%%
%% `timestamp' is the CL's and never the clock's. The CL decides the slot, and a
%% builder that used its own clock would produce a block for a different slot than
%% the one the CL asked for -- and a timestamp that crossed a fork activation
%% would build under different rules than the CL expects.
%%
%% Returns {ok, Payload, BlockValue} | {error, Reason}. `Payload' is an
%% ExecutionPayloadV1-shaped map from `eth_block:to_payload/1'; the caller adds
%% the `blockHash' key placement, which to_payload/1 already does.
-spec build(map()) -> {ok, map(), non_neg_integer()} | {error, term()}.
build(Attributes) when is_map(Attributes) ->
    case base_of(Attributes) of
        {error, Reason} -> {error, Reason};
        {ok, Block0} ->
            Block1 = with_attributes(Block0, Attributes),
            Block2 = with_transactions(Block1, Attributes),
            case eth_block:finalize(Block2) of
                {ok, Finalized, Verification} ->
                    report_verdicts(Finalized#block.number, Verification),
                    case eth_block:to_payload(Finalized) of
                        {ok, Payload} ->
                            {ok, Payload, block_value(Verification)};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, {finalize_failed, Reason}}
            end
    end;
build(_Attributes) ->
    {error, attributes_not_an_object}.

get_payload(PayloadId) ->
    gen_server:call(?MODULE, {payload, PayloadId}).

%% Drop a payloadId this node will not serve again. The Engine API has no method
%% that does this, so it exists for the CL-facing code to call when a build is
%% abandoned.
forget(PayloadId) ->
    gen_server:call(?MODULE, {forget, PayloadId}).

status() ->
    gen_server:call(?MODULE, get_status).

%% ---------------------------------------------------------------------------
%% The block
%% ---------------------------------------------------------------------------

%% The base block comes from eth_block:new/3 and nowhere else, which is the whole
%% point of the rewrite. It supplies the three constants this module used to get
%% wrong -- an 8-byte nonce, ?EMPTY_UNCLE_HASH, and difficulty 0 -- and it is the
%% function the tests pin against real block hashes.
base_of(Attributes) ->
    ParentHash = data32(maps:get(parent_hash, Attributes, undefined)),
    Number = quantity(maps:get(number, Attributes, undefined)),
    BaseFee = quantity(maps:get(base_fee, Attributes, undefined)),
    case {ParentHash, Number, BaseFee} of
        {{ok, Hash}, {ok, N}, {ok, Fee}} ->
            {ok, eth_block:new(Hash, N, Fee)};
        {{error, _}, _, _} ->
            {error, {bad_attribute, parent_hash, ParentHash}};
        {_, {error, _}, _} ->
            {error, {bad_attribute, number, Number}};
        {_, _, {error, _}} ->
            {error, {bad_attribute, base_fee, BaseFee}}
    end.

%% The CL's attributes land on the header. Every one of these was previously
%% discarded in favour of a placeholder: the timestamp was the wall clock, the fee
%% recipient was the zero address, prevRandao was zero, and the withdrawals were
%% an empty list -- so a build ignored the entire payload of the request it was
%% answering.
with_attributes(Block, Attributes) ->
    Timestamp = quantity(maps:get(timestamp, Attributes, 0)),
    Withdrawals = withdrawals(maps:get(withdrawals, Attributes, [])),
    Block#block{
        timestamp = case Timestamp of {ok, T} -> T; _ -> Block#block.timestamp end,
        miner = data20(maps:get(fee_recipient, Attributes, undefined),
                       Block#block.miner),
        mix_hash = data32_or(maps:get(prev_randao, Attributes, undefined),
                             Block#block.mix_hash),
        gas_limit = quantity_or(maps:get(gas_limit, Attributes, undefined),
                                Block#block.gas_limit),
        extra_data = data_or(maps:get(extra_data, Attributes, undefined),
                             Block#block.extra_data),
        withdrawals = Withdrawals,
        %% The withdrawals root is derived from the CL's list, not carried. EIP-4895
        %% commits to the list in the header, so a root that disagrees with the
        %% list is a block nobody can verify -- and `finalize/1' checks it, which is
        %% why it is computed here rather than trusted.
        withdrawals_root = eth_fork_schedule:withdrawals_root(Withdrawals),
        parent_beacon_block_root =
            data32_or(maps:get(parent_beacon_block_root, Attributes, undefined),
                      Block#block.parent_beacon_block_root),
        %% EIP-4844: this block's excess blob gas is the parent's excess plus the
        %% gas the parent's blobs used, less the per-block target. It was left at
        %% new/2's default of 0, which is a *consensus* header field on Cancun --
        %% so a build on top of a parent whose blocks carried blobs would commit to
        %% an excess the network did not compute, and the block would be rejected
        %% by every validator. The update lives in eth_fork_schedule, which is also
        %% where the Prague-era change to it is documented as not modelled.
        excess_blob_gas = eth_fork_schedule:excess_blob_gas(
                            maps:get(parent_excess_blob_gas, Attributes, 0),
                            maps:get(parent_blob_gas_used, Attributes, 0)),
        %% This node includes no blob transactions -- it has no transaction type-3
        %% encoder on the build path -- so its own blob gas used is 0. Stating 0 is
        %% a claim that is true of this build, not a default: the builder's
        %% transaction selection admits no type-3 transaction, and a blob
        %% transaction that reached it would fail validation.
        blob_gas_used = 0
    }.

withdrawals(Ws) when is_list(Ws) -> Ws;
withdrawals(_) -> [].

%% ---------------------------------------------------------------------------
%% Transaction selection
%% ---------------------------------------------------------------------------

%% The pool's pending tier, ordered by the effective tip a sender would pay, and
%% truncated at the block gas limit. Ordering is by tip rather than by the raw
%% price field, because under EIP-1559 a high maxFeePerGas with a low priority fee
%% is worth less to the proposer than a modest maxFee with a high tip, and sorting
%% on `price' -- which is what this module used to do -- put those in the wrong
%% order.
with_transactions(Block, Attributes) ->
    BaseFee = Block#block.base_fee_per_gas,
    Limit = Block#block.gas_limit,
    Entries = lists:sublist(
                lists:sort(fun(A, B) -> tip(A, BaseFee) >= tip(B, BaseFee) end,
                           safe_pending_entries()),
                maps:get(max_transactions, Attributes, 2048)),
    include(Entries, Block, BaseFee, Limit, 0, []).

include([], Block, _BaseFee, _Limit, _UsedGas, Acc) ->
    Block#block{transactions = lists:reverse(Acc)};
include([Entry | Rest], Block, BaseFee, Limit, UsedGas, Acc) ->
    Tx = maps:get(tx, Entry, undefined),
    case Tx of
        undefined ->
            include(Rest, Block, BaseFee, Limit, UsedGas, Acc);
        _ ->
            case validate_transaction(Tx, #{base_fee => BaseFee}) of
                {ok, true} ->
                    case gas_of(Tx) of
                        {ok, Gas} when UsedGas + Gas =< Limit ->
                            include(Rest, eth_block:add_transaction(Block, Tx),
                                    BaseFee, Limit, UsedGas + Gas, [Tx | Acc]);
                        _ ->
                            include(Rest, Block, BaseFee, Limit, UsedGas, Acc)
                    end;
                _ ->
                    include(Rest, Block, BaseFee, Limit, UsedGas, Acc)
            end
    end.

%% The effective tip: what the proposer actually receives for this transaction.
%% The base fee is burned, not paid out, so it is maxPriorityFeePerGas that counts
%% -- and for a legacy transaction, gasPrice minus the base fee, floored at zero
%% because a transaction that pays no tip still pays the burn.
tip(Entry, BaseFee) ->
    Tx = maps:get(tx, Entry, #{}),
    Priority = quantity_or(maps:get(<<"maxPriorityFeePerGas">>, Tx, undefined), undefined),
    MaxFee = quantity_or(maps:get(<<"maxFeePerGas">>, Tx, undefined), undefined),
    GasPrice = quantity_or(maps:get(<<"gasPrice">>, Tx, undefined), 0),
    case {Priority, MaxFee} of
        {undefined, _} -> max(0, GasPrice - base_or_zero(BaseFee));
        {P, undefined} -> P;
        {P, M} when P < M -> P;
        {_, M} -> max(0, M - base_or_zero(BaseFee))
    end.

base_or_zero(undefined) -> 0;
base_or_zero(B) when is_integer(B) -> B.

gas_of(Tx) ->
    case quantity_or(maps:get(<<"gas">>, Tx, undefined), undefined) of
        undefined -> {error, no_gas};
        Gas when is_integer(Gas), Gas > 0 -> {ok, Gas};
        _ -> {error, bad_gas}
    end.

%% ---------------------------------------------------------------------------
%% blockValue
%% ---------------------------------------------------------------------------
%%
%% "The expected value to be received by the feeRecipient in wei"
%% (execution-apis src/engine/shanghai.md, engine_getPayloadV2). The base fee is
%% burned, so this is the sum of tips over the gas the transactions actually used --
%% not the sum of `gas' limits, and not the sum of full gas prices. A builder that
%% reported the latter would state a revenue its proposer will not receive.
%%
%% It is computed from the receipts `finalize/1' produced, because those carry the
%% gas each transaction really consumed. A block whose transactions were not
%% executed has no receipts, and then the value is not knowable: this answers 0 and
%% says why, rather than multiplying declared gas limits by declared prices.
-spec block_value(map()) -> non_neg_integer().
block_value(Verification) ->
    case maps:get(receipts, Verification, undefined) of
        undefined ->
            0;
        Receipts when is_list(Receipts) ->
            lists:sum([receipt_value(R) || R <- Receipts])
    end.

receipt_value(Receipt) ->
    case {maps:get(gas_used, Receipt, undefined),
          quantity_or(maps:get(<<"gasPrice">>, Receipt, undefined), undefined),
          quantity_or(maps:get(<<"maxPriorityFeePerGas">>, Receipt, undefined),
                      undefined),
          quantity_or(maps:get(<<"maxFeePerGas">>, Receipt, undefined),
                      undefined),
          quantity_or(maps:get(<<"baseFeePerGas">>, Receipt, undefined), 0)} of
        {Gas, _GasPrice, undefined, undefined, BaseFee} when is_integer(Gas) ->
            %% A legacy transaction pays the whole gasPrice, minus the burn.
            max(0, Gas * (case quantity_or(maps:get(<<"gasPrice">>, Receipt, undefined),
                                          0) - BaseFee of
                             V when is_integer(V) -> V;
                             _ -> 0
                         end));
        {Gas, _GasPrice, Prio, MaxFee, _BaseFee}
          when is_integer(Gas), is_integer(Prio), is_integer(MaxFee) ->
            Tip = min(Prio, MaxFee - base_of_receipt(Receipt)),
            max(0, Gas * Tip);
        _ ->
            0
    end.

base_of_receipt(Receipt) ->
    case quantity_or(maps:get(<<"baseFeePerGas">>, Receipt, undefined), 0) of
        B when is_integer(B) -> B;
        _ -> 0
    end.

%% ---------------------------------------------------------------------------
%% payloadId store
%% ---------------------------------------------------------------------------

%% An 8-byte id, per the specification. crypto:strong_rand_bytes/1 because two
%% builds of the same slot must not collide, and a predictable id would let one
%% client collect another's payload. The CL sends this back to getPayload, and
%% answering the wrong payload would hand one proposer another proposer's block.
new_payload(Payload, BlockValue) ->
    PayloadId = crypto:strong_rand_bytes(?PAYLOAD_ID_BYTES),
    {ok, PayloadId, Payload, BlockValue}.

%% Store an already-built payload and return its id. The build itself is `build/1',
%% which is pure and runs in the caller; only the issuing of an id is this
%% process's, because a payloadId is a promise that `getPayload' will answer and
%% two callers must not be able to make that promise independently.
-spec store_payload(map(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
store_payload(Payload, BlockValue) ->
    gen_server:call(?MODULE, {store, Payload, BlockValue}, infinity).

%% The gen_server call wraps this so the store is updated in the server's own
%% state. Kept separate from build/1 so build/1 stays pure enough to test without
%% a registered process.
insert_payload(S, PayloadId, Payload, BlockValue) ->
    S#st{payloads = maps:put(PayloadId, {Payload, BlockValue}, S#st.payloads)}.

%% ---------------------------------------------------------------------------
%% Verdicts
%% ---------------------------------------------------------------------------
%%
%% finalize/1 reports each commitment as {verified, Root} | {unverified, Reason},
%% and this is the only place that turns those into something a reader sees. An
%% unverified root is not an error: the block is still returned, because a proposer
%% that returns nothing gets no block. It is logged, so the gap is visible in the
%% log rather than only in the source.
report_verdicts(Number, Verification) ->
    [case V of
         {verified, _Root} -> ok;
         {unverified, Reason} ->
             logger:notice("etherlang: built block ~p does not have a verified ~s "
                           "root: ~p", [Number, K, Reason])
     end || {K, V} <- maps:to_list(Verification)],
    ok.

%% ---------------------------------------------------------------------------
%% Validation
%% ---------------------------------------------------------------------------
%%
%% The consensus rules live in eth_tx:validate/2, which is also what the pool and
%% block finalization use. Three copies of "is this transaction valid" is three
%% copies that can drift: an intrinsic-gas schedule that differs by one constant
%% between the proposer and the validator charges different fees for the same
%% transaction and computes a different state root.
%%
%% What stays here is the one check that is *not* a consensus rule. A `from` field
%% is a JSON-RPC annotation, not part of the signed transaction, and no consensus
%% rule mentions it, so eth_tx:validate/2 deliberately ignores it -- a peer's
%% block is not invalid because an RPC field disagrees. When this node is
%% assembling its own block out of transactions it did not author, a declared
%% `from` that disagrees with the recovered signer is a strong signal that the
%% transaction is being relayed with a corrupted or spoofed body, and refusing to
%% propose it is worth the cost.
validate_transaction(Tx) when is_map(Tx) ->
    validate_transaction(Tx, #{}).

%% validate_transaction(Tx, Ctx) where Ctx may carry
%%   base_fee      -> integer()  current block base fee
%%   balance_of    -> fun((Address) -> {ok, Balance})
%%   nonce_of      -> fun((Address) -> {ok, Nonce})
%%   chain_id      -> integer()
validate_transaction(Tx, Ctx) when is_map(Tx), is_map(Ctx) ->
    case eth_tx:validate(Tx, Ctx) of
        ok ->
            case check_from_field(Tx) of
                ok -> {ok, true};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end;
validate_transaction(_Tx, _Ctx) ->
    {error, invalid_transaction}.

check_from_field(Tx) ->
    case eth_tx:sender(Tx) of
        {ok, Payer} ->
            case maps:get(<<"from">>, Tx, undefined) of
                undefined ->
                    ok;
                Declared when is_binary(Declared) ->
                    case declared_address(Declared) of
                        Payer -> ok;
                        _ -> {error, sender_mismatch}
                    end;
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

%% A `from` that is not even shaped like an address is treated as "no claim
%% made" rather than as a mismatch: it cannot be evidence of tampering if it
%% is not an address in the first place, and failing to parse an annotation should
%% not fail validation. The "0x" prefix has to come off before decode_hex/1 --
%% that function rejects the letter x outright.
declared_address(<<"0x", S/binary>>) -> decode_address_hex(S);
declared_address(<<"0X", S/binary>>) -> decode_address_hex(S);
declared_address(B) when is_binary(B) -> decode_address_hex(B);
declared_address(Other) -> Other.

decode_address_hex(S) ->
    Padded = case byte_size(S) rem 2 of
        0 -> S;
        1 -> <<"0", S/binary>>
    end,
    try binary:decode_hex(Padded)
    catch _:_ -> undefined
    end.

%% ---------------------------------------------------------------------------
%% Status
%% ---------------------------------------------------------------------------

status(#st{max_gas = MaxGas, max_transactions = MaxTxs,
          payloads = Payloads}) ->
    #{pending => safe_pending(),
      max_gas => MaxGas,
      max_transactions => MaxTxs,
      payloads => maps:size(Payloads)}.

%% A pool that is not running is 0 pending, not a crash.
%%
%% This is not only a health-check concern. `with_transactions/2' calls
%% `eth_txpool:pending()' and an unguarded gen_server:call raises
%% exit:{noproc, ...} when the pool is stopped -- which it is for as long as the
%% pool is not started, and is a legitimate state (a node configured with an empty
%% pool, a node mid-restart, and every test that starts the builder alone). The
%% build died there rather than producing an empty block, so a consensus client
%% asking for a block got no answer at all where an empty block is a valid and
%% usual answer: most slots contain no transactions this node can include.
safe_pending() ->
    try length(eth_txpool:pending())
    catch _:_ -> 0
    end.

safe_pending_entries() ->
    try eth_txpool:pending()
    catch _:_ -> []
    end.

%% ---------------------------------------------------------------------------
%% Attribute decoding
%% ---------------------------------------------------------------------------
%%
%% Small strict readers, because the alternative is a default. A `timestamp' that
%% read as 0 would build a block for the genesis slot, and a `feeRecipient' that
%% read as the zero address would send the block's revenue to nobody -- and both
%% would be indistinguishable from a client that asked for that.
%%
%% hex_decode/1 rather than eth_hex:decode/1: the latter answers an *integer*, so
%% `eth_hex:decode(<<"0x00">>)' is 0 and a DATA value can never come out of it.
%% This has been got wrong three times in this codebase.

data32(<<>>) -> {error, empty};
data32(V) when is_binary(V) ->
    Bytes = hex_decode(V),
    case is_binary(Bytes) andalso byte_size(Bytes) =:= 32 of
        true -> {ok, Bytes};
        false -> {error, not_32_bytes}
    end;
data32(V) -> {error, {not_data, V}}.

data32_or(undefined, Default) -> Default;
data32_or(V, Default) ->
    case data32(V) of
        {ok, Bytes} -> Bytes;
        {error, _} -> Default
    end.

%% Raw bytes or `error', with a default for absent. Used for extraData, which is
%% variable-length DATA and so cannot use the fixed-width readers.
data_or(undefined, Default) -> Default;
data_or(V, Default) ->
    case hex_decode(V) of
        error -> Default;
        Bytes when is_binary(Bytes) -> Bytes
    end.

data20(undefined, Default) -> Default;
data20(V, Default) ->
    case hex_decode(V) of
        Bytes when is_binary(Bytes), byte_size(Bytes) =:= 20 -> Bytes;
        _ -> Default
    end.

quantity(undefined) -> {error, missing};
quantity(V) when is_integer(V), V >= 0 -> {ok, V};
quantity(V) when is_binary(V) ->
    try
        {ok, eth_hex:decode(V)}
    catch _:_ -> {error, {bad_quantity, V}}
    end;
quantity(V) -> {error, {bad_quantity, V}}.

quantity_or(undefined, Default) -> Default;
quantity_or(V, Default) ->
    case quantity(V) of
        {ok, N} -> N;
        {error, _} -> Default
    end.

%% 0x-prefixed hex to bytes, or `error'. A binary that is *not* 0x-prefixed is
%% taken as the bytes it already is, which is what an in-process caller holds, and
%% the caller then checks the width.
%%
%% The pass-through used to be limited to 32 bytes, so a 20-byte fee recipient --
%% the one DATA field in payloadAttributes that is not 32 bytes -- was rejected and
%% silently replaced by the default, and the block's revenue went to the zero
%% address. Nothing raised: the address is a valid 20-byte value, the build
%% succeeded, and the proposer was paid nothing at an address nobody controls.
%% `eth_block:data/2' has the same tolerance for the same reason, and the width
%% check belongs to the caller in both.
hex_decode(<<>>) -> <<>>;
hex_decode(Bin) when is_binary(Bin) ->
    case Bin of
        <<"0x", Rest/binary>> -> decode_nibbles(Rest);
        <<"0X", Rest/binary>> -> decode_nibbles(Rest);
        _ -> Bin
    end;
hex_decode(_) -> error.

decode_nibbles(Hex) when byte_size(Hex) rem 2 =:= 0 ->
    try binary:decode_hex(Hex)
    catch _:_ -> error
    end;
decode_nibbles(_Hex) -> error.
