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
