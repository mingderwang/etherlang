-module(eth_tx_validity_tests).

%% Transaction validity, and the state effects a valid transaction has.
%%
%% Two things are under test here and they are the same thing, because they are
%% two halves of one rule: a transaction is either allowed to change the state,
%% in which case every effect the protocol says it has must actually happen, or
%% it is refused, in which case nothing happens at all.
%%
%% Both halves were missing. The validating path (eth_block:execute_transactions)
%% checked *nothing* -- no nonce, no balance, no chain id, no signature -- and
%% the execution path applied *nothing*: the EVM ran the code and the nonce was
%% never bumped, the value was never transferred, the coinbase was never paid
%% and the gas was never bought. A node in that state accepts invalid blocks and
%% computes a state root that no other client can reproduce, from code that ran
%% correctly.

-include_lib("eunit/include/eunit.hrl").
-include("eth_block.hrl").

-define(PROBE, <<16#c0:160>>).
-define(COINBASE, <<0:160>>).
-define(EMPTY_CODE_HASH, <<0:256>>).
-define(WEI, 1000000000000000000).

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

with_ctx(Fun) ->
    ensure_started(eth_mpt),
    ok = eth_mpt:clear(),
    Previous = eth_state:base_source(),
    ok = eth_state:set_base_source(mpt),
    try Fun()
    after
        _ = eth_state:set_base_source(Previous),
        _ = clear_mpt(),
        _ = stop_chain()
    end.

ensure_started(Mod) ->
    case whereis(Mod) of
        undefined -> {ok, Pid} = Mod:start_link(), Pid;
        Pid -> Pid
    end.

ensure_started(Mod, Arg) ->
    case whereis(Mod) of
        undefined -> {ok, Pid} = Mod:start_link(Mod, Arg), Pid;
        Pid -> Pid
    end.

clear_mpt() ->
    try eth_mpt:clear() catch _:_ -> ok end.

stop_chain() ->
    try gen_server:stop(eth_chain) catch _:_ -> ok end.

hex(B) -> <<"0x", (string:lowercase(binary:encode_hex(B)))/binary>>.
hex_to_bin(<<"0x", Rest/binary>>) -> binary:decode_hex(Rest).

store_parent(ParentRoot) ->
    ensure_started(eth_chain, eth_test_util:tmp_dir()),
    Base = eth_test_util:header(0, hex(<<0:256>>), 0),
    Block = Base#{
              <<"totalDifficulty">> => eth_hex:encode_int(0),
              <<"size">> => eth_hex:encode_int(600),
              <<"stateRoot">> => hex(ParentRoot)
             },
    {ok, HashHex} = eth_header:verify(Block),
    ok = eth_chain:append([{0, Block#{<<"hash">> => HashHex}, true}]),
    hex_to_bin(HashHex).

new_key() ->
    Priv = eth_secp256k1:generate_key(),
    Sender = binary:part(eth_keccak:hash(eth_secp256k1:node_id(Priv)),
                         12, 20),
    {Priv, Sender}.

%% Fund an address in the MPT at a given balance and nonce.
fund(Addr, Balance, Nonce) ->
    ok = eth_mpt:put_account(Addr, Balance, Nonce, ?EMPTY_CODE_HASH).

%% A real signed legacy transaction for the configured chain. Every test that
%% expects a transaction to be *accepted* goes through here, so a fixture can
%% never be quietly invalid for a reason the test is not about.
signed(Priv, Fields) ->
    Nonce = maps:get(nonce, Fields, 0),
    GasPrice = maps:get(gas_price, Fields, 0),
    Gas = maps:get(gas, Fields, 100000),
    To = maps:get(to, Fields, ?PROBE),
    Value = maps:get(value, Fields, 0),
    Data = maps:get(input, Fields, <<>>),
    ChainId = maps:get(chain_id, Fields, eth_fork_schedule:chain_id()),
    Digest = eth_keccak:hash(
               eth_rlp:encode([Nonce, GasPrice, Gas, To, Value, Data,
                               ChainId, 0, 0])),
    {R, S, V} = eth_secp256k1:sign(Digest, Priv),
    Vv = case maps:get(unprotected, Fields, false) of
             true -> 27 + V;
             false -> ChainId * 2 + 35 + V
         end,
    Tx = #{<<"type">> => <<"0x0">>,
           <<"nonce">> => eth_hex:encode_int(Nonce),
           <<"gasPrice">> => eth_hex:encode_int(GasPrice),
           <<"gas">> => eth_hex:encode_int(Gas),
           <<"to">> => hex(To),
           <<"value">> => eth_hex:encode_int(Value),
           <<"input">> => hex(Data),
           <<"v">> => eth_hex:encode_int(Vv),
           <<"r">> => hex(int_to_32(R)),
           <<"s">> => hex(int_to_32(S))},
    maps:merge(Tx, maps:get(extra, Fields, #{})).

int_to_32(V) -> <<V:256/unsigned-big>>.

%% A block ready to finalize: its parent's declared state root is the MPT's own
%% root, which is the condition finalize/1 requires before it will execute.
child_block(Parent, Number, Txs) ->
    (eth_block:new(Parent, Number))#block{transactions = Txs,
                                          miner = ?COINBASE}.

%% A child block whose fee collector is a known address, so the coinbase payment
%% is observable rather than going to the default zero address.
child_block_to(Parent, Number, Txs, Miner) ->
    (child_block(Parent, Number, Txs))#block{miner = Miner}.

%% Store a finalized block so the next one can name it as a parent.
%%
%% This is not bookkeeping. finalize/1 only executes when the local MPT provably
%% holds the *parent's* state, so chaining two blocks means the first has to be
%% both finalized (which writes its post-state) and stored (which is how the next
%% block finds its parent's declared state root). Skipping the store leaves the
%% next block reporting state_not_local and never validating anything -- which
%% looks like a pass and is the opposite.
chain(Finalized) ->
    Map = eth_block:to_json(Finalized),
    {ok, HashHex} = eth_header:verify(Map),
    ok = eth_chain:append([{Finalized#block.number, Map#{<<"hash">> => HashHex}, true}]),
    hex_to_bin(HashHex).

%% Run one block of transactions and return the finalized block.
finalize(Parent, Number, Txs) ->
    {ok, Finalized, _V} = eth_block:finalize(child_block(Parent, Number, Txs)),
    Finalized.

committed(Addr) ->
    case eth_mpt:get_account(Addr) of
        undefined -> undefined;
        A -> A
    end.

committed_balance(Addr) ->
    case committed(Addr) of
        undefined -> undefined;
        A -> maps:get(balance, A, 0)
    end.

committed_nonce(Addr) ->
    case committed(Addr) of
        undefined -> undefined;
        A -> maps:get(nonce, A, 0)
    end.

committed_code(Addr) ->
    case committed(Addr) of
        undefined -> undefined;
        A -> eth_mpt:get_code(maps:get(codeHash, A, ?EMPTY_CODE_HASH))
    end.

%% ---------------------------------------------------------------------------
%% Validity: a block containing an invalid transaction is not finalized
%% ---------------------------------------------------------------------------
%%
%% The refusal has to come from finalize/1, not from a helper, because finalize/1
%% is the only place a peer's block body is read. Validating in a function that
%% finalize/1 does not call would leave the hole exactly where it was.

valid_nonce_is_required_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Good = signed(Priv, #{to => ?PROBE, gas => 100000, value => 0}),
        %% Executed once and only once: finalizing is not idempotent, because it
        %% commits the post-state, so a second run would apply the same block on
        %% top of its own result and declare a root no peer has.
        First = finalize(Parent, 1, [Good]),
        ?assertEqual(21000, First#block.gas_used),
        %% The account nonce is 1 after that block, so 5 is now a gap. The block
        %% has to be chained for the check to run at all.
        Parent2 = chain(First),
        Gap = signed(Priv, #{to => ?PROBE, gas => 100000, value => 0, nonce => 5}),
        ?assertEqual({error, {invalid_transaction, 0, bad_nonce}},
                     eth_block:finalize(child_block(Parent2, 2, [Gap])))
    end).

stale_nonce_is_a_replay_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 3),
        Parent = store_parent(eth_mpt:state_root()),
        Replay = signed(Priv, #{to => ?PROBE, gas => 100000, value => 0, nonce => 1}),
        ?assertEqual({error, {invalid_transaction, 0, bad_nonce}},
                     eth_block:finalize(child_block(Parent, 1, [Replay])))
    end).

unfunded_sender_is_rejected_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        %% Enough for the gas but not for the value on top of it.
        fund(Sender, 21000, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Tx = signed(Priv, #{to => ?PROBE, gas => 21000, gas_price => 1, value => 1}),
        ?assertEqual({error, {invalid_transaction, 0, insufficient_balance}},
                     eth_block:finalize(child_block(Parent, 1, [Tx])))
    end).

foreign_chain_id_is_rejected_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Foreign = signed(Priv, #{to => ?PROBE, gas => 100000, chain_id => 1}),
        ?assertEqual({error, {invalid_transaction, 0, wrong_chain_id}},
                     eth_block:finalize(child_block(Parent, 1, [Foreign])))
    end).

%% EIP-155 replay protection is the reason an unprotected legacy transaction is
%% invalid here. "No chain id" is not the same answer as "the right chain id".
unprotected_legacy_is_rejected_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Unprotected = signed(Priv, #{to => ?PROBE, gas => 100000, unprotected => true}),
        ?assertEqual({error, {invalid_transaction, 0, wrong_chain_id}},
                     eth_block:finalize(child_block(Parent, 1, [Unprotected])))
    end).

gas_below_intrinsic_is_rejected_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        %% 20999 is one gas short of the 21000 a transfer costs before it starts.
        Short = signed(Priv, #{to => ?PROBE, gas => 20999}),
        ?assertEqual({error, {invalid_transaction, 0, intrinsic_gas}},
                     eth_block:finalize(child_block(Parent, 1, [Short]))),
        Exact = signed(Priv, #{to => ?PROBE, gas => 21000}),
        ?assertMatch({ok, _, _}, eth_block:finalize(child_block(Parent, 2, [Exact])))
    end).

unrecoverable_signature_is_rejected_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Zeroed = signed(Priv, #{to => ?PROBE, gas => 100000,
                                extra => #{<<"r">> => <<"0x0">>}}),
        ?assertEqual({error, {invalid_transaction, 0, bad_signature}},
                     eth_block:finalize(child_block(Parent, 1, [Zeroed])))
    end).

%% EIP-2: an s above the half-order is the other signature over the same message,
%% so accepting it would make a transaction hash ambiguous.
malleable_s_is_rejected_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        N = 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
        S = eth_hex:decode(maps:get(<<"s">>, signed(Priv, #{}))),
        Flipped = eth_hex:encode_int(N - S),
        Tampered = signed(Priv, #{to => ?PROBE, gas => 100000,
                                  extra => #{<<"s">> => Flipped}}),
        ?assertEqual({error, {invalid_transaction, 0, bad_signature}},
                     eth_block:finalize(child_block(Parent, 1, [Tampered])))
    end).

fee_below_base_fee_is_rejected_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Cheap = signed(Priv, #{to => ?PROBE, gas => 100000, gas_price => 1}),
        Block = (child_block(Parent, 1, [Cheap]))#block{base_fee_per_gas = 1000},
        ?assertEqual({error, {invalid_transaction, 0, fee_too_low}},
                     eth_block:finalize(Block))
    end).

%% A transaction that does not fit in the block's remaining gas cannot be in the
%% block, however valid it is on its own. The second one here fits; the third
%% does not, and is refused at the point the running total makes it impossible.
block_gas_limit_is_enforced_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        One = signed(Priv, #{to => ?PROBE, gas => 21000, nonce => 0}),
        Two = signed(Priv, #{to => ?PROBE, gas => 21000, nonce => 1}),
        Block = (child_block(Parent, 1, [One, Two]))#block{gas_limit = 21000},
        ?assertEqual({error, {invalid_transaction, 1, exceeds_block_gas_limit}},
                     eth_block:finalize(Block))
    end).

a_refused_block_changes_nothing_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        {_Priv2, Recipient} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        RootBefore = eth_mpt:state_root(),
        Bad = signed(Priv, #{to => Recipient, gas => 100000, value => ?WEI,
                             nonce => 9}),
        {error, _} = eth_block:finalize(child_block(Parent, 1, [Bad])),
        %% The refund, the transfer and the nonce bump must not have happened:
        %% the transaction never ran, so the state is untouched.
        ?assertEqual(?WEI * 1000, committed_balance(Sender)),
        ?assertEqual(0, committed_nonce(Sender)),
        ?assertEqual(undefined, committed(Recipient)),
        ?assertEqual(RootBefore, eth_mpt:state_root())
    end).

%% ---------------------------------------------------------------------------
%% State effects: a valid transaction actually moves the state
%% ---------------------------------------------------------------------------

sender_nonce_advances_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        _ = finalize(Parent, 1, [signed(Priv, #{to => ?PROBE, gas => 100000})]),
        ?assertEqual(1, committed_nonce(Sender))
    end).

%% Two transactions from one sender in one block: the second must see the
%% account nonce the first one left behind. This is the test that the nonce bump
%% is not merely present but correctly *ordered* against validation.
sequential_nonces_execute_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Txs = [signed(Priv, #{to => ?PROBE, gas => 100000, nonce => N})
               || N <- [0, 1, 2]],
        Finalized = finalize(Parent, 1, Txs),
        ?assertEqual(3, length(Finalized#block.receipts)),
        ?assertEqual(3, committed_nonce(Sender))
    end).

value_is_transferred_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        {_Priv2, Recipient} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        Value = 3 * ?WEI,
        _ = finalize(Parent, 1,
                     [signed(Priv, #{to => Recipient, gas => 100000,
                                      value => Value})]),
        ?assertEqual(1000 * ?WEI - Value, committed_balance(Sender)),
        ?assertEqual(Value, committed_balance(Recipient))
    end).

%% The recipient's balance is the whole story of the transfer, but the *sender's*
%% is not Value: it also paid gas. Asserting the exact remainder is what pins the
%% gas accounting down rather than allowing it to be wrong in either direction.
gas_is_paid_at_the_offered_price_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        {_Priv2, Recipient} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        GasPrice = 10,
        Value = ?WEI,
        Finalized = finalize(Parent, 1,
                             [signed(Priv, #{to => Recipient, gas => 100000,
                                              gas_price => GasPrice,
                                              value => Value})]),
        Used = Finalized#block.gas_used,
        ?assertEqual(21000, Used),
        ?assertEqual(1000 * ?WEI - Value - Used * GasPrice,
                     committed_balance(Sender))
    end).

%% EIP-1559: the sender is charged at its cap, the unused part comes back at the
%% effective price, and the coinbase gets the tip -- which is the effective price
%% *less* the base fee. The base fee portion is burned, so the block's total
%% tracked balance is short by exactly gasUsed * baseFee.
base_fee_is_burned_and_the_tip_paid_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        {_Priv2, Miner} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        fund(Miner, 0, 0),
        Parent = store_parent(eth_mpt:state_root()),
        BaseFee = 7,
        MaxPriority = 3,
        %% The cap is set to exactly the metered price, BaseFee + MaxPriority,
        %% which is what a sender does when it is not gambling on a rising base
        %% fee. The effective price is then min(10, 7 + 3) = 10 and the tip is
        %% 10 - 7 = 3, and -- because the cap is not above the effective price --
        %% the sender ends up paying the effective price for the gas it used and
        %% nothing at all for the gas it did not.
        MaxFee = BaseFee + MaxPriority,
        Tx = #{<<"type">> => <<"0x2">>,
              <<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
              <<"nonce">> => <<"0x0">>,
              <<"maxPriorityFeePerGas">> => eth_hex:encode_int(MaxPriority),
              <<"maxFeePerGas">> => eth_hex:encode_int(MaxFee),
              <<"gas">> => eth_hex:encode_int(100000),
              <<"to">> => hex(?PROBE),
              <<"value">> => <<"0x0">>,
              <<"input">> => <<"0x">>,
              <<"yParity">> => <<"0x0">>},
        {R, S, Y} = sign_1559(Priv, Tx),
        Signed = Tx#{<<"r">> => hex(int_to_32(R)),
                     <<"s">> => hex(int_to_32(S)),
                     <<"v">> => eth_hex:encode_int(Y)},
        %% The base fee has to be on the *header*. eth_block:new/2 leaves it
        %% undefined, and an undefined base fee is pre-London, where a 1559
        %% transaction has no effective price at all and pays nothing -- so a
        %% test that sets BaseFee as a variable but forgets to put it on the
        %% block is not testing what it says it is.
        {ok, Finalized, _V} = eth_block:finalize(
            (child_block_to(Parent, 1, [Signed], Miner))#block{
                base_fee_per_gas = BaseFee}),
        Used = Finalized#block.gas_used,
        Effective = min(MaxFee, BaseFee + MaxPriority),
        Tip = Effective - BaseFee,
        ?assertEqual(Used * Tip, committed_balance(Miner)),
        %% The sender paid exactly the gas it used, at the effective price.
        ?assertEqual(1000 * ?WEI - Used * Effective, committed_balance(Sender)),
        %% And what is left of it is gone: not in the sender, not in the miner.
        %% This is the base fee being burned, and it is the only thing the base
        %% fee does -- it is not redistributed to anybody.
        ?assertEqual(Used * BaseFee,
                     1000 * ?WEI - committed_balance(Sender)
                     - committed_balance(Miner))
    end).

sign_1559(Priv, Tx) ->
    F = [eth_hex:decode(maps:get(<<"chainId">>, Tx)),
         eth_hex:decode(maps:get(<<"nonce">>, Tx)),
         eth_hex:decode(maps:get(<<"maxPriorityFeePerGas">>, Tx)),
         eth_hex:decode(maps:get(<<"maxFeePerGas">>, Tx)),
         eth_hex:decode(maps:get(<<"gas">>, Tx)),
         hex_to_bin(maps:get(<<"to">>, Tx)),
         eth_hex:decode(maps:get(<<"value">>, Tx)),
         hex_to_bin(maps:get(<<"input">>, Tx)),
         []],
    Digest = eth_keccak:hash(<<16#02, (eth_rlp:encode(F))/binary>>),
    eth_secp256k1:sign(Digest, Priv).

unspent_gas_comes_back_at_the_effective_price_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        {_Priv2, Miner} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        fund(Miner, 0, 0),
        Parent = store_parent(eth_mpt:state_root()),
        MaxFee = 1000,
        Tx = #{<<"type">> => <<"0x2">>,
              <<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
              <<"nonce">> => <<"0x0">>,
              <<"maxPriorityFeePerGas">> => eth_hex:encode_int(1),
              <<"maxFeePerGas">> => eth_hex:encode_int(MaxFee),
              <<"gas">> => eth_hex:encode_int(100000),
              <<"to">> => hex(?PROBE),
              <<"value">> => <<"0x0">>,
              <<"input">> => <<"0x">>},
        {R, S, Y} = sign_1559(Priv, Tx),
        Signed = Tx#{<<"r">> => hex(int_to_32(R)),
                     <<"s">> => hex(int_to_32(S)),
                     <<"v">> => eth_hex:encode_int(Y)},
        BaseFee = 10,
        {ok, Finalized, _V} = eth_block:finalize(
            (child_block(Parent, 1, [Signed]))#block{
                base_fee_per_gas = BaseFee, miner = Miner}),
        Used = Finalized#block.gas_used,
        Unused = 100000 - Used,
        Effective = min(MaxFee, BaseFee + 1),
        ?assertEqual(21000, Used),
        %% The cap is charged for the whole limit and the *unused* gas comes back
        %% at the effective price -- not at the cap, and not at the base fee. So
        %% the sender is out 100000 * 1000 - 79000 * 11, and the part of that
        %% which is neither the effective price nor the tip is the base fee burnt
        %% on gas the transaction never used. This is the whole reason 1559 sends
        %% people away with a high cap, and it is not a bug.
        ?assertEqual(1000 * ?WEI - (100000 * MaxFee - Unused * Effective),
                     committed_balance(Sender)),
        ?assertEqual(Used * (Effective - BaseFee), committed_balance(Miner))
    end).

%% EIP-161: touching an address that does not exist must not bring it into being.
%% A zero-value transfer is the only way to touch an address without funding it,
%% and getting this wrong puts an empty account in the trie, which changes the
%% state root.
zero_value_transfer_does_not_create_the_account_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        {_Priv2, Ghost} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        _ = finalize(Parent, 1, [signed(Priv, #{to => Ghost, gas => 100000,
                                                value => 0})]),
        ?assertEqual(undefined, committed(Ghost))
    end).

%% ...but a transfer of actual value does create it, because then it is not
%% empty. The two cases together are the whole EIP-161 rule.
non_zero_transfer_creates_the_account_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        {_Priv2, Fresh} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        _ = finalize(Parent, 1, [signed(Priv, #{to => Fresh, gas => 100000,
                                                value => 1})]),
        ?assertEqual(1, committed_balance(Fresh))
    end).

%% The coinbase is touched even when the tip is zero, and must not survive as an
%% empty account either.
untouched_coinbase_is_not_created_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        _ = finalize(Parent, 1, [signed(Priv, #{to => ?PROBE, gas => 100000,
                                                gas_price => 0})]),
        ?assertEqual(undefined, committed(?COINBASE))
    end).


%% A transaction that reverts still consumed its nonce and still paid for its
%% gas. Only the contract's own state changes are undone. This is the difference
%% between a revert and a refused block, and conflating them is how a node ends
%% up letting a sender replay a transaction that already failed.
revert_keeps_the_nonce_and_pays_gas_test() ->
    with_ctx(fun() ->
        %% PUSH1 0 PUSH1 0 REVERT -- always reverts, costs 0 gas of its own.
        Code = <<16#60, 0, 16#60, 0, 16#FD>>,
        ok = eth_mpt:put_code(eth_keccak:hash(Code), Code),
        ok = eth_mpt:put_account(?PROBE, 0, 0, eth_keccak:hash(Code)),
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        _ = finalize(Parent, 1, [signed(Priv, #{to => ?PROBE, gas => 100000,
                                                gas_price => 2})]),
        ?assertEqual(1, committed_nonce(Sender)),
        ?assertEqual(1000 * ?WEI - 21006 * 2, committed_balance(Sender))
    end).

%% A creation deploys at keccak(rlp([sender, nonce]))[12:] with nonce 1, and the
%% returned code is what the account ends up holding.
creation_deploys_at_the_derived_address_test() ->
    with_ctx(fun() ->
        %% Init code: write one byte (0x00 = STOP) to memory[0] and return it.
        Code = <<16#60, 16#00, 16#60, 0, 16#52,
                16#60, 1, 16#60, 0, 16#F3>>,
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Parent = store_parent(eth_mpt:state_root()),
        _ = finalize(Parent, 1, [signed(Priv, #{to => <<>>, gas => 200000,
                                                input => Code})]),
        Expected = binary:part(eth_keccak:hash(
                                 eth_rlp:encode([Sender, 0])), 12, 20),
        ?assertEqual(<<16#00>>, committed_code(Expected)),
        ?assertEqual(1, committed_nonce(Expected)),
        ?assertEqual(1, committed_nonce(Sender))
    end).

%% ---------------------------------------------------------------------------
%% eth_tx:validate/2 on its own
%% ---------------------------------------------------------------------------
%%
%% The state-dependent rules are only checkable through finalize/1, but the
%% decoding rules are not, and they are the ones with a subtlety worth pinning:
%% `r' and `s' are 32-byte DATA while `nonce' and `value' are QUANTITY, and
%% treating either as the other is a bug that only shows up on real traffic --
%% roughly one signature in 256 has a leading zero byte.

r_and_s_are_data_not_quantities_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = signed(Priv, #{to => ?PROBE, gas => 100000}),
    Ctx = #{chain_id => eth_fork_schedule:chain_id()},
    %% signed/2 emits r and s zero-padded to 32 bytes, which is how a real node
    %% returns them. A zero leading byte here is the *correct* encoding, so the
    %% same value spelled as a minimal quantity must not be treated as malformed
    %% either -- recovery only ever depends on the integer.
    ?assertEqual(64, byte_size(maps:get(<<"r">>, Tx)) - 2),
    Minimal = Tx#{<<"r">> => eth_hex:encode_int(eth_hex:decode(maps:get(<<"r">>, Tx))),
                 <<"s">> => eth_hex:encode_int(eth_hex:decode(maps:get(<<"s">>, Tx)))},
    ?assertEqual(ok, eth_tx:validate(Tx, Ctx)),
    ?assertEqual(ok, eth_tx:validate(Minimal, Ctx)),
    %% The other fields really are QUANTITY, and a leading zero is malformed
    %% there. The two rules differ, and applying one to the other's fields is the
    %% bug this pins.
    ?assertEqual({error, {non_canonical_quantity, <<"nonce">>}},
                 eth_tx:validate(Tx#{<<"nonce">> => <<"0x00">>})),
    ?assertEqual({error, {non_canonical_quantity, <<"value">>}},
                 eth_tx:validate(Tx#{<<"value">> => <<"0x0001">>})),
    %% Zero is legitimately spelled with one digit.
    ?assertEqual(ok, eth_tx:validate(Tx, Ctx)),
    ?assertEqual(ok, eth_tx:validate(Tx#{<<"nonce">> => <<"0x0">>}, Ctx)).

an_unreadable_signature_component_is_a_bad_field_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = signed(Priv, #{to => ?PROBE, gas => 100000}),
    ?assertMatch({error, {bad_field, <<"r">>}},
                 eth_tx:validate(Tx#{<<"r">> => <<"0xzz">>})),
    ?assertMatch({error, {bad_field, <<"s">>}},
                 eth_tx:validate(Tx#{<<"s">> => <<"0xzz">>})).

%% An absent signature field and a corrupt one are different faults, and both
%% are refusals.
a_missing_signature_field_is_a_bad_signature_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = signed(Priv, #{to => ?PROBE, gas => 100000}),
    ?assertEqual({error, bad_signature},
                 eth_tx:validate(maps:remove(<<"s">>, Tx))).

%% An absent context key means the rule is not checked, not that it passed. The
%% distinction matters because a caller with no view of the sender cannot confirm
%% a nonce, and "cannot tell" reported as "valid" is indistinguishable from a
%% real answer.
an_absent_context_key_does_not_check_that_rule_test() ->
    Priv = eth_secp256k1:generate_key(),
    Tx = signed(Priv, #{to => ?PROBE, gas => 100000, nonce => 42}),
    ?assertEqual(ok, eth_tx:validate(Tx)),
    ?assertEqual({error, bad_nonce},
                 eth_tx:validate(Tx, #{nonce_of => fun(_) -> {ok, 7} end})),
    ?assertEqual(ok,
                 eth_tx:validate(Tx, #{nonce_of => fun(_) -> {ok, 42} end})).

%% The builder, the pool and finalization all ask eth_tx:intrinsic_gas/1. They
%% used to carry three copies between them, and two of them charged a contract
%% creation the plain transfer price.
the_intrinsic_floor_is_the_same_everywhere_test() ->
    Priv = eth_secp256k1:generate_key(),
    Call = signed(Priv, #{to => ?PROBE, gas => 100000}),
    Create = signed(Priv, #{to => <<>>, gas => 100000, input => <<>>}),
    ?assertEqual(21000, eth_tx:intrinsic_gas(Call)),
    ?assertEqual(53000, eth_tx:intrinsic_gas(Create)).

%% ---------------------------------------------------------------------------
%% Intrinsic gas is priced under a fork
%% ---------------------------------------------------------------------------
%%
%% EIP-3860's 2-gas-per-word init-code charge is Shanghai's, and it is the only
%% term of a transaction's intrinsic gas that moves with the fork. This was charged
%% unconditionally, so a pre-Shanghai creation transaction was refused for
%% carrying gas it does not owe: 32 bytes of init code is one word, and the floor
%% was 2 too high, which is enough to reject a transaction minted exactly at the
%% pre-Shanghai floor.

%% The term, measured rather than restated, so a change to the schedule cannot
%% make both sides of this wrong together.
%%
%% Every assertion here is *relative* to the same transaction at London, and
%% deliberately not an absolute figure. The calldata itself is charged too -- four
%% gas a zero byte, sixteen a non-zero one -- so an absolute number would be
%% asserting the calldata rate as well, and would have been wrong for a reason
%% that has nothing to do with the fork. What is under test is how much the fork
%% moves the floor, and nothing else.
initcode_gas_is_only_charged_from_shanghai_test() ->
    Priv = eth_secp256k1:generate_key(),
    %% 64 bytes of init code: exactly two 32-byte words.
    Data = <<0:512>>,
    Create = signed(Priv, #{to => <<>>, gas => 200000, input => Data}),
    Words = (byte_size(Data) + 31) div 32,
    ?assertEqual(2, Words),
    Base = eth_tx:intrinsic_gas(Create, london),
    Pre = [frontier, homestead, byzantium, constantinople, petersburg, istanbul,
           berlin, london, paris, merge],
    Post = [shanghai, cancun, prague, osaka],
    %% Before Shanghai the floor does not move with the fork.
    [?assertEqual(Base, eth_tx:intrinsic_gas(Create, F)) || F <- Pre],
    %% From Shanghai it carries two gas a word for the init code, and only that.
    [?assertEqual(Base + 2 * Words, eth_tx:intrinsic_gas(Create, F)) || F <- Post],
    %% A call carries no init code at all, so the fork cannot move its floor.
    Call = signed(Priv, #{to => ?PROBE, gas => 200000}),
    CallBase = eth_tx:intrinsic_gas(Call, london),
    [?assertEqual(CallBase, eth_tx:intrinsic_gas(Call, F)) || F <- Pre ++ Post],
    %% And the call's floor really is the plain transfer price, so the "does not
    %% move" assertion above is not vacuous.
    ?assertEqual(21000, CallBase).

%% A creation whose init code is not a whole number of words still pays for the
%% partial word, at both ends of the fork boundary. This is the rounding a length
%% argument gets wrong most easily, and the boundary sits exactly at 32 bytes: at
%% 31 the fork makes no difference and at 32 it makes one of 2.
initcode_gas_rounds_a_partial_word_up_at_both_forks_test() ->
    Priv = eth_secp256k1:generate_key(),
    Floor = fun(Len) ->
        signed(Priv, #{to => <<>>, gas => 200000, input => <<0:(Len * 8)>>})
    end,
    %% Every length from 1 to 65 bytes: the Shanghai floor is London's plus two
    %% gas per word, rounded up, with no length at which the two agree.
    [begin
         T = Floor(Len),
         ?assertEqual(2 * ((Len + 31) div 32),
                      eth_tx:intrinsic_gas(T, shanghai) -
                          eth_tx:intrinsic_gas(T, london))
     end || Len <- lists:seq(1, 65)],
    %% The calldata rate moves with the length too, so the *total* floor is not
    %% just the creation price plus a word count. Asserted so that a future
    %% reader does not "simplify" the difference above into an absolute figure.
    ?assertNotEqual(eth_tx:intrinsic_gas(Floor(1), london),
                    eth_tx:intrinsic_gas(Floor(33), london)).

%% The one-argument form falls back to the operator's pin, and says so.
%%
%% It is a documented weakening rather than a resolution: no block exists at
%% admission, so there is nothing better to say. What it must not be is a
%% *different* answer from the two-argument form under the same fork, or a
%% validator and a block executor would price the same transaction differently
%% for no stated reason.
intrinsic_gas_without_a_fork_matches_the_pinned_fork_test() ->
    Priv = eth_secp256k1:generate_key(),
    Create = signed(Priv, #{to => <<>>, gas => 200000, input => <<0:512>>}),
    Pinned = eth_fork_schedule:configured_fork(),
    ?assertEqual(eth_tx:intrinsic_gas(Create, Pinned),
                 eth_tx:intrinsic_gas(Create)),
    ?assertEqual(eth_tx:intrinsic_gas(signed(Priv, #{to => ?PROBE, gas => 100000}),
                                      Pinned),
                 eth_tx:intrinsic_gas(signed(Priv, #{to => ?PROBE, gas => 100000}))).

%% ---------------------------------------------------------------------------
%% The block's own fork reaches the intrinsic-gas floor
%% ---------------------------------------------------------------------------
%%
%% EIP-3860's init-code term is Shanghai's, so a creation transaction's floor is a
%% function of the block it would go in. Two things have to be true for that to
%% hold, and neither was observable before:
%%
%%   * eth_block:validation_ctx/4 puts the *block's* fork in the context, rather
%%     than leaving eth_tx to fall back to the operator's ETH_FORK pin; and
%%   * eth_tx:validate/2 reads that fork out of the context.
%%
%% Both were found untested by injection, not by reading: hardcoding the fork
%% inside eth_tx, and separately dropping it from eth_block's context, each left
%% every test in this module green. The table was pinned; the wiring was not.
%%
%% The observable is a transaction minted exactly at the pre-Shanghai floor. It
%% is accepted by a pre-Shanghai block and refused by a post-Shanghai one, because
%% the latter requires two more gas per word of init code than the sender offered.
%% A transaction that sits well above both floors would pass either way and prove
%% nothing, which is why the `gas' below is the London floor and not a round
%% number.
the_intrinsic_floor_follows_the_blocks_own_fork_test() ->
    with_ctx(fun() ->
        %% One word of init code, so the Shanghai floor is exactly 2 higher.
        Code = <<16#60, 16#00, 16#60, 0, 16#52,
                16#60, 1, 16#60, 0, 16#F3>>,
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        London = eth_tx:intrinsic_gas(
                   signed(Priv, #{to => <<>>, gas => 200000, input => Code}),
                   london),
        ?assertEqual(London, eth_tx:intrinsic_gas(
                              signed(Priv, #{to => <<>>, gas => 200000,
                                             input => Code}), paris)),
        ?assertEqual(London + 2, eth_tx:intrinsic_gas(
                                  signed(Priv, #{to => <<>>, gas => 200000,
                                                 input => Code}), shanghai)),
        Mint = signed(Priv, #{to => <<>>, gas => London, input => Code}),

        %% The precondition: the two blocks really are on opposite sides of
        %% Shanghai. Sepolia activates it at 1677557088, and `fork/1' reads the
        %% block's own timestamp, so this is the only thing that differs.
        ?assertEqual(london, fork_at(0)),
        ?assertEqual(shanghai, fork_at(1677557088)),

        %% Refused by the post-Shanghai block, which does charge the term.
        %% Deliberately first: a refused block commits nothing, so the chain
        %% store and the trie are untouched and the next block can be built off
        %% the same parent. `store_parent/1' always anchors at height 0, so the
        %% two blocks cannot be chained -- the order is what makes them
        %% comparable rather than a sequence.
        Parent = store_parent(eth_mpt:state_root()),
        ?assertMatch({error, {invalid_transaction, 0, intrinsic_gas}},
                     eth_block:finalize(stamped(Parent, 1, [Mint], 1677557088))),

        %% And accepted by the pre-Shanghai block, which does not. Same
        %% transaction, same sender, same declared gas -- only the block's
        %% timestamp differs, so the difference in outcome is the fork.
        {ok, _, _} = eth_block:finalize(stamped(Parent, 1, [Mint], 0))
    end).

%% The block fork the test above depends on, resolved the way the node resolves
%% it, so the precondition cannot drift from the thing under test.
fork_at(Timestamp) ->
    {ok, F} = eth_fork_schedule:current_fork(
                eth_fork_schedule:configured_network(), 1, Timestamp),
    F.

stamped(Parent, Number, Txs, Timestamp) ->
    (child_block(Parent, Number, Txs))#block{timestamp = Timestamp}.

%% The *other* place the block's fork is used, and the one a validator test
%% cannot see.
%%
%% eth_block computes the intrinsic floor twice: once inside eth_tx:validate/2,
%% which decides acceptance, and once again in run_transaction/5 to work out how
%% much gas the EVM frame starts with. The second use is not observable through
%% acceptance -- a frame that is two gas short or two gas long still runs -- so
%% dropping the block's fork there left every test green while quietly moving
%% `gasUsed' by two gas per word of init code. `gasUsed' is a receipt field, the
%% receipts root is in the block header, and the header is hashed.
%%
%% So the observable is the receipts root: two blocks differing only in
%% timestamp, each executing the same transaction at a gas limit both forks
%% accept, must produce *different* receipts roots. Were the floor taken from one
%% fork for both, the roots would be equal -- and equal roots are exactly what a
%% node reports when it has stopped pricing per fork.
%% ---------------------------------------------------------------------------
%% EIP-7623: the calldata floor, end to end
%% ---------------------------------------------------------------------------
%%
%% The table test pins the arithmetic. This pins the two things only execution can
%% show, and the second is the one that is easy to get wrong:
%%
%%   1. the floor raises the transaction's `gasUsed', which is a receipt field and
%%      so a receipts root and a block hash;
%%   2. **the sender pays it.** `settle_gas/8' settles a sender by refunding the
%%      unused allowance against the price `buy_gas/4' charged, so a `gasUsed' that is
%%      raised *after* that settlement is a number the sender was never billed. The
%%      first version of this fix did exactly that: the receipt said 21,010 and the
%%      coinbase was paid a tip on 21,010, while the sender's balance still showed
%%      21,009. `gasUsed' would have been right and the post-state wrong, which is a
%%      divergence that does not announce itself -- both numbers are plausible.
%%
%% A one-zero-byte transaction whose frame uses almost nothing keeps the arithmetic
%% checkable: the floor is 21,010 and the intrinsic is 21,004, so the floor is six
%% above it and the difference is not lost in the frame's own cost.

the_calldata_floor_is_charged_to_the_sender_and_reported_test() ->
    with_ctx(fun() ->
        {ok, Prague} = eth_fork_schedule:current_fork(
                         eth_fork_schedule:configured_network(), 1, 1750000000),
        ?assertEqual(prague, Prague),
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        %% `0x00' is one zero byte: one token, so the floor is 21000 + 10.
        Tx = signed(Priv, #{to => ?PROBE, gas => 100000, gas_price => 1,
                            input => <<0>>}),
        Block = (eth_block:new(<<0:256>>, 1))#block{timestamp = 1750000000,
                                                    gas_limit = 1000000},
        {Block1, State1} = eth_block:run_transaction(Block, Tx, eth_state:new(0, #{}),
                                                    undefined, 1000000),
        [Receipt] = Block1#block.receipts,
        GasUsed = maps:get(<<"gasUsed">>, Receipt),
        ?assertEqual(21010, GasUsed),
        %% And the sender's balance fell by the floor at the price, not by the
        %% intrinsic. This is the assertion that would have failed on the first
        %% version, because the receipt and the balance disagreed there and the
        %% receipt was the one under test.
        ?assertEqual(1000 * ?WEI - 21010,
                     eth_state:balance(State1, Sender))
    end).

%% The floor is a Prague rule, so the same transaction at Cancun is billed its
%% intrinsic and nothing more. Without this, "the sender pays the floor" could be
%% satisfied by a sender that always charges 21,010.
the_calldata_floor_is_not_charged_before_prague_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        Tx = signed(Priv, #{to => ?PROBE, gas => 100000, gas_price => 1,
                            input => <<0>>}),
        Block = (eth_block:new(<<0:256>>, 1))#block{timestamp = 1720000000,
                                                    gas_limit = 1000000},
        ?assertEqual(cancun, fork_at(1720000000)),
        {Block1, State1} = eth_block:run_transaction(Block, Tx, eth_state:new(0, #{}),
                                                    undefined, 1000000),
        [Receipt] = Block1#block.receipts,
        ?assert(21010 > maps:get(<<"gasUsed">>, Receipt)),
        ?assertEqual(1000 * ?WEI - maps:get(<<"gasUsed">>, Receipt),
                     eth_state:balance(State1, Sender))
    end).

%% The validity half: a transaction whose limit is below the floor cannot rely on
%% execution to cover it, so it is rejected outright.
a_transaction_below_the_calldata_floor_is_rejected_at_prague_test() ->
    with_ctx(fun() ->
        {Priv, Sender} = new_key(),
        fund(Sender, 1000 * ?WEI, 0),
        %% One non-zero byte is four tokens, so the floor is 21040, and the
        %% intrinsic is 21016. A limit of 21020 clears the intrinsic and not the
        %% floor, which is the case the EIP's second paragraph is about.
        Tx = signed(Priv, #{to => ?PROBE, gas => 21020, gas_price => 1,
                            input => <<1>>}),
        State = eth_state:new(0, #{{balance, Sender} => 1000 * ?WEI,
                                  {nonce, Sender} => 0}),
        Ctx = #{base_fee => undefined, gas_limit => 1000000, gas_used => 0,
                chain_id => eth_fork_schedule:chain_id(), fork => prague,
                balance_of => fun(A) -> {ok, eth_state:balance(State, A)} end,
                nonce_of => fun(A) -> {ok, eth_state:nonce(State, A)} end},
        ?assertMatch({error, calldata_floor}, eth_tx:validate(Tx, Ctx)),
        %% And one gas more is accepted, so the threshold is the floor and not a
        %% round number or the intrinsic.
        Ok = signed(Priv, #{to => ?PROBE, gas => 21040, gas_price => 1,
                           input => <<1>>}),
        ?assertEqual(ok, eth_tx:validate(Ok, Ctx)),
        ?assert(london =/= prague)
    end).

%% ---------------------------------------------------------------------------
%% The transaction *type* is a fork question, and it is not a decode question
%% ---------------------------------------------------------------------------
%% A typed transaction is a new wire format, so a fork that never defined the type
%% cannot have a block containing one. The corpus found this as a validator that
%% **accepted** an EIP-1559 transaction inside a Berlin block: `validate/2' checked
%% only that the type was one it could decode, which is a statement about the code
%% rather than about the block.
%%
%% No valid signature is needed for any of this. `validate/2' deliberately does not
%% recover the sender -- a node validating a block it did not build must accept the
%% sender the block says -- so these fixtures carry placeholder v/r/s, and a test
%% that needed a real one would be testing recovery rather than the fork gate.

a_type_two_transaction_is_rejected_before_london_test() ->
    Tx = typed_1559(#{<<"gas">> => 100000}),
    ?assertEqual({error, tx_type_pre_fork},
                 eth_tx:validate(Tx, ctx_at(berlin, Tx))),
    ?assertEqual({error, tx_type_pre_fork},
                 eth_tx:validate(Tx, ctx_at(byzantium, Tx))),
    %% One fork later it is valid, which is what makes the gate a fork question and
    %% not a rejection of type 2 as such.
    ?assertEqual(ok, eth_tx:validate(Tx, ctx_at(london, Tx))).

a_type_one_transaction_is_rejected_before_berlin_test() ->
    Tx = typed_1559(#{<<"gas">> => 100000, <<"accessList">> => []}),
    Tx1 = Tx#{<<"type">> => <<"0x1">>},
    ?assertEqual({error, tx_type_pre_fork},
                 eth_tx:validate(Tx1, ctx_at(istanbul, Tx1))),
    ?assertEqual(ok, eth_tx:validate(Tx1, ctx_at(berlin, Tx1))).

a_type_three_transaction_is_rejected_before_cancun_test() ->
    %% This is the regression the missing `ctx_fork/1' resolution caused: ten
    %% blob-transaction tests across three modules failed on the day the type gate
    %% went in, and all ten were one defect rather than ten.
    Tx = (typed_1559(#{<<"gas">> => 100000}))#{
             <<"type">> => <<"0x3">>,
             <<"maxFeePerBlobGas">> => <<"0x3b9aca00">>,
             <<"blobVersionedHashes">> =>
                 %% A versioned hash whose 31-byte remainder is *not* all zeros.
                 %% `valid_versioned_hashes/1' rejects an all-zero remainder
                 %% explicitly, so the obvious placeholder fails here -- and for a
                 %% real reason rather than a formatting one.
                 [<<16#01, 1:248>>]},
    ?assertEqual({error, tx_type_pre_fork},
                 eth_tx:validate(Tx, ctx_at(london, Tx))),
    ?assertEqual(ok, eth_tx:validate(Tx, ctx_at(cancun, Tx))).

a_forkless_context_resolves_to_the_operator_pin_test() ->
    %% `eth_tx:ctx_fork/1' had `Fork when is_atom(Fork) -> Fork' as its first
    %% clause, and `undefined' is an atom, so the *default* was returned as though
    %% it were a fork and `configured_fork/0' below it was unreachable for every
    %% context without a `fork' key -- which is every pool and block-builder call.
    %% Nothing announced it, because `undefined' satisfies every `is_atom(Fork)'
    %% guard downstream, so the schedules it reached simply answered for a fork
    %% named `undefined'.
    %%
    %% EIP-7623's floor is what exposed it. Its `calldata_floor/2' answers 0 for a
    %% fork it does not recognise, so with the fork unresolved the floor silently
    %% vanished and a transaction below it validated. One zero calldata byte has a
    %% floor of 21,010 and an intrinsic of 21,004, so a limit of 21,005 is the
    %% whole gap between the two.
    with_env("ETH_FORK", "prague", fun() ->
        Tx = typed_1559(#{<<"gas">> => 21005, <<"input">> => <<"0x00">>}),
        Ctx = #{base_fee => undefined, gas_limit => 30000, gas_used => 0,
                chain_id => eth_fork_schedule:chain_id(),
                balance_of => fun(_) -> {ok, 1000 * ?WEI} end,
                nonce_of => fun(_) -> {ok, 0} end},
        ?assertEqual(prague, eth_fork_schedule:configured_fork()),
        ?assertMatch({error, calldata_floor}, eth_tx:validate(Tx, Ctx)),
        %% The floor is the only thing at issue, so the same transaction at the
        %% floor is accepted -- otherwise "rejected" could be satisfied by the
        %% intrinsic rule alone and the test would prove nothing about EIP-7623.
        Ok = typed_1559(#{<<"gas">> => 21010, <<"input">> => <<"0x00">>}),
        ?assertEqual(ok, eth_tx:validate(Ok, Ctx))
    end).

%% ---------------------------------------------------------------------------

typed_1559(Fields) ->
    maps:merge(#{<<"type">> => <<"0x2">>,
                 <<"chainId">> => eth_hex:encode_int(eth_fork_schedule:chain_id()),
                 <<"nonce">> => <<"0x0">>,
                 <<"maxPriorityFeePerGas">> => <<"0x1">>,
                 <<"maxFeePerGas">> => <<"0x2">>,
                 <<"gas">> => eth_hex:encode_int(100000),
                 <<"to">> => hex(?PROBE),
                 <<"value">> => <<"0x0">>,
                 <<"input">> => <<"0x">>,
                 %% A placeholder signature. `validate/2' does not recover the
                 %% sender, and a real one would only make these tests test recovery.
                 <<"v">> => <<"0x1">>, <<"r">> => <<"0x1">>, <<"s">> => <<"0x1">>},
            Fields).

ctx_at(Fork, _Tx) ->
    #{base_fee => undefined, gas_limit => 1000000, gas_used => 0,
      chain_id => eth_fork_schedule:chain_id(), fork => Fork,
      %% A funded sender, because a zero balance fails the balance rule and would
      %% make "accepted at London" unsatisfiable for a reason that is not the fork.
      balance_of => fun(_) -> {ok, 1000 * ?WEI} end,
      nonce_of => fun(_) -> {ok, 0} end}.

with_env(Name, Value, Fun) ->
    Previous = os:getenv(Name),
    true = os:putenv(Name, Value),
    try Fun()
    after
        case Previous of
            false -> os:unsetenv(Name);
            _ -> os:putenv(Name, Previous)
        end
    end.

the_evm_allowance_follows_the_blocks_own_fork_test() ->
    Code = <<16#60, 16#00, 16#60, 0, 16#52,
             16#60, 1, 16#60, 0, 16#F3>>,
    Root = fun(Timestamp) ->
        with_ctx(fun() ->
            {Priv, Sender} = new_key(),
            fund(Sender, 1000 * ?WEI, 0),
            %% A limit both forks accept, so acceptance cannot be what differs.
            Tx = signed(Priv, #{to => <<>>, gas => 100000, input => Code}),
            Parent = store_parent(eth_mpt:state_root()),
            {ok, _Block, Verification} =
                eth_block:finalize(stamped(Parent, 1, [Tx], Timestamp)),
            %% `verified' and not `unverified': an unrooted execution would satisfy
            %% "the two differ" for a reason that has nothing to do with the fork.
            {verified, R} = maps:get(receipts_root, Verification),
            R
        end)
    end,
    ?assertEqual(london, fork_at(0)),
    ?assertEqual(shanghai, fork_at(1677557088)),
    London = Root(0),
    Shanghai = Root(1677557088),
    %% Both blocks really executed and reported a root, rather than either
    %% leaving the field absent -- without this, "they differ" could be satisfied
    %% by one of them being `unverified'.
    ?assert(is_binary(London)),
    ?assert(is_binary(Shanghai)),
    ?assertEqual(32, byte_size(London)),
    ?assertEqual(32, byte_size(Shanghai)),
    %% And they differ, which is the whole claim: the same transaction, the same
    %% declared gas, and a different receipts root because the frame it was given
    %% was sized under a different fork's floor.
    ?assertNotEqual(London, Shanghai).
