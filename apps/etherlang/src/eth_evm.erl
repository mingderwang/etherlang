-module(eth_evm).

%% Pure-Erlang EVM interpreter for `eth_call` simulation.
%%
%% Design notes:
%%  * State is layered on `eth_state`: reads fall through to the upstream node
%%    and are cached, while all writes (SSTORE, transfers, created code) live
%%    in an immutable overlay that is discarded on revert. Upstream state is
%%    never mutated.
%%  * Gas is a close approximation, not a per-fork exact schedule; it exists to
%%    bound execution. Local execution is opportunistic: on an unsupported
%%    opcode or precompile the caller falls back to the upstream node.
%%  * CALL/CREATE recurse through `run/5`. Depth is capped at 1024.

-record(e, {code = <<>>, pc = 0, stack = [], mem = <<>>, gas = 0,
            retdata = <<>>, halt = undefined, logs = [], refund = 0,
            dests = undefined}).

%% `originals' holds, per (address, slot), the value that slot held when the
%% *transaction* began -- EIP-2200's `original'. It is a different thing from
%% `transient' in the one respect that matters: a child frame's transient writes
%% must vanish when it reverts, because they belong to the frame. An original
%% value belongs to the transaction and must *survive* a revert, because the slot
%% is back to what it was and the next write still needs the same original.
%%
%% That is why it is a separate map rather than a reserved key in the transient
%% one. The invariant that makes it safe to handle the two identically: a child's
%% map starts as a copy of the parent's and only ever gains entries, and an entry
%% is a transaction-start value, so the child can never disagree with the parent
%% about one. The child's map is therefore the correct one on *both* the success
%% and the revert path, and no merge rule is needed.
-record(ctx, {state, env, msg, transient = #{}, originals = #{}, fork}).

-export([run/5,
           initial_access/3, valid_jumpdests/1]).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------
%% run(Code, Msg, State, Env, Gas) ->
%%   {ok, Output, GasLeft, State, Logs}
%% | {revert, Output, GasLeft, State, Logs}
%% | {error, Reason, State, Logs}
run(Code, Msg, State, Env, Gas) when is_binary(Code) ->
    Fork = fork_of(Env),
    {Res, _Transient, _Originals} =
        run_t(Code, Msg, State, Env, Gas, initial_access(Msg, Env, Fork), #{}, Fork),
    Res.

%% EIP-2929, "When a transaction execution begins", in the EIP's own words:
%%
%%   - `accessed_storage_keys' is initialized to empty, and
%%   - `accessed_addresses' is initialized to include
%%     - the `tx.sender', `tx.to' (or the address being created if it is a contract
%%       creation transaction)
%%     - and the set of all precompiles.
%%
%% **None of it was seeded.** `run/5' began the transient map empty, so the first
%% `BALANCE' of the transaction's own recipient, a `CALL' to any precompile, and
%% anything touching the sender were each charged `COLD_ACCOUNT_ACCESS_COST'.
%%
%% The corpus named it as a uniform +2,500 across twenty-four fixtures, and 2,500 is
%% `COLD_ACCOUNT_ACCESS_COST - WARM_STORAGE_READ_COST' exactly -- 2,600 - 100 -- at
%% every fork from Berlin and at no fork before it. The "+2,500 at Berlin and later
%% only" is what identifies it as a precompile rather than anything else: the
%% `test_gas.py' contracts behind those fixtures call one precompile each and do
%% nothing else, and their forwarded gas is one gas short of the precompile's price, so
%% the call fails and the only thing left to price is the *access* to it.
%%
%% `accessed_storage_keys` is genuinely empty here, so there is nothing to seed on that
%% side; the clause is noted rather than left implied, because a reader checking
%% EIP-2929's list against this function will look for it.
%%
%% Berlin-gated because EIP-2929 introduces the access list as well as this rule, and
%% because below Berlin `access_cost/3' ignores `warm' -- so seeding earlier would be
%% harmless and would also be a claim about a fork whose schedule has no such concept.
initial_access(Msg, Env, Fork) ->
    case eth_fork_schedule:at_least(Fork, berlin) of
        false ->
            #{};
        true ->
            %% The key is `{warm_account, Addr}' and not the bare address, because
            %% that is the key `warm_account/2' looks up. Seeding under a different
            %% key would produce a map that looks populated and prices every access
            %% cold -- which is the bug, reproduced inside the fix for it.
            %% `maps:get/3' on the message, not `s_msg/3' -- which takes a `#ctx{}' and
            %% reads `Ctx#ctx.msg', and this function runs *before* a context exists. I
            %% wrote `s_msg/3' first and every test in `eth_evm_tests' failed, because
            %% `Msg#ctx.msg' on a plain map is a badrecord and the interpreter cannot
            %% start a frame at all.
            Addrs = [maps:get(origin, Msg, <<0:160>>),
                     maps:get(address, Msg, <<0:160>>)]
                    ++ coinbase_at(Fork, maps:get(coinbase, Env, undefined))
                    ++ eth_fork_schedule:precompile_addresses(Fork),
            Warmed = lists:foldl(fun(Addr, Acc) -> Acc#{{warm_account, Addr} => true} end,
                                 #{}, Addrs),
            access_list_access(Msg, Warmed)
    end.

%% EIP-2930, quoted at the point of use: "The address and storage keys would be
%% **immediately loaded** into the accessed_addresses and accessed_storage_keys global
%% sets; this can be done using the following logic (which doubles as a
%% specification-in-code of validation of the RLP-decoded access list)."
%%
%% The **addresses** were already warm: the frame's own `address` is the transaction's
%% recipient, and a list naming any other address adds only that address. The **storage
%% keys** are the whole of it -- a `(address, key)` pair the list declared is warm from
%% the first instruction, so the `SLOAD` that reads it costs 100 rather than 2,100. That
%% is the EIP's entire purpose, and it was not happening.
%%
%% **The slot is converted to an integer here, and that is load-bearing.** `SLOAD` and
%% `SSTORE` both `pop` the slot off the stack -- where it is a word -- and hand it
%% straight to `warm_store/3`, so the key the interpreter looks up is
%% `{warm_store, Addr, 0}`. The list carries 32 bytes, and `{warm_store, Addr,
%% <<0:256>>}` is a **different key**. Writing the right value under a key nothing reads
%% is a warm set that is present, correct-looking and completely inert -- the same
%% asymmetry `eth_state:slot_key/1' has with `eth_mpt:encode_slot/1', and the third time
%% this repository has met it.
%%
%% The entries arrive already normalised by `eth_tx:access_list_field/1' as
%% `{Address, [Slot]}` with **raw** 20- and 32-byte binaries. A malformed list cannot
%% reach here: `access_list_field/1` throws and `eth_tx:validate/2' calls it before any
%% frame runs, so the clause below is a fallback rather than a validator.
access_list_access(Msg, Warmed) ->
    case maps:get(access_list, Msg, []) of
        L when is_list(L) ->
            lists:foldl(fun({Addr, Slots}, Acc) ->
                                lists:foldl(fun(Slot, A) ->
                                                    A#{{warm_store, Addr,
                                                        binary:decode_unsigned(Slot)}
                                                       => true}
                                            end, Acc, Slots)
                        end, Warmed, L);
        _ ->
            Warmed
    end.

%% **EIP-3651: the coinbase is warm from the first instruction of the transaction.**
%% "At the start of transaction execution, accessed_addresses shall be initialized to
%% also include the address returned by COINBASE (0x41)." Shanghai, and gated like every
%% other arrival rather than written in unconditionally.
%%
%% The EIP's own reason is the one worth keeping, because it is the *same* argument as
%% the sender and `to' and not a discount: "The COINBASE address should also always be
%% loaded because it receives the block reward and the transaction fees." Without it,
%% every direct payment to the miner is charged `COLD_ACCOUNT_ACCESS_COST` (2,600) on
%% first touch, and a contract that pays the coinbase and branches on the result -- the
%% pattern EIP-3651 exists for -- is charged as though it were reading an account it had
%% never heard of.
%%
%% `maps:get/3' and not `maps:get/2': a caller that omits `coinbase' from the Env has
%% not said the coinbase is `<<0:160>>', it has said nothing, and warming the zero
%% address would be a warm entry nothing in the frame can use.
coinbase_at(Fork, Addr) ->
    case Addr =/= undefined andalso eth_fork_schedule:at_least(Fork, shanghai) of
        true -> [Addr];
        false -> []
    end.

%% The fork this frame executes under, taken from the Env.
%%
%% It is a required key, not an optional one with a default. The alternative --
%% defaulting to the newest fork, or to the operator's ETH_FORK pin -- means a
%% caller who forgets to set it gets a frame that runs instructions its block
%% never had, which is not a wrong answer to a question but the wrong question:
%% the state root afterwards is not a value any other client can reproduce, and
%% nothing in the result says so. A `badkey' here is the loud version of that,
%% and every Env builder in src/ sets it (eth_call:env_from_block/2,
%% eth_block:block_env/2, eth_fork_schedule:run_system_call/6).
fork_of(Env) -> maps:get(fork, Env).

%% Internal run threading EIP-1153 transient storage. The transient map is
%% transaction-global: a child frame inherits a copy of the parent map and,
%% on success, its writes merge back (child wins); on revert/error the
%% parent map is kept unchanged.
run_t(Code, Msg, State, Env, Gas, Transient, Originals, Fork) when is_binary(Code) ->
    Ctx = #ctx{state = State, env = Env, msg = Msg, transient = Transient,
               originals = Originals, fork = Fork},
    E0 = #e{code = Code, gas = max(Gas, 0), dests = valid_jumpdests(Code)},
    try exec(E0, Ctx) of
        {E1, Ctx1} ->
            GasUsed = E0#e.gas - E1#e.gas,
            %% EIP-2200 (Berlin) capped refunds at gasUsed/2; EIP-3529 (London)
            %% cut that to gasUsed/5. The cap was Berlin's divisor while the
            %% refund amounts it capped were London's, so a London frame could
            %% hand back up to half of what it spent when the rule allows a
            %% fifth. See eth_fork_schedule:refund_cap/2.
            MaxRefund = eth_fork_schedule:refund_cap(Fork, GasUsed),
            Refund = min(E1#e.refund, MaxRefund),
            FinalGas = E1#e.gas + Refund,
            Res = case E1#e.halt of
                      {return, Out} -> {ok, Out, FinalGas, Ctx1#ctx.state, E1#e.logs};
                      stop -> {ok, <<>>, FinalGas, Ctx1#ctx.state, E1#e.logs};
                      {revert, Out} -> {revert, Out, FinalGas, Ctx1#ctx.state, E1#e.logs};
                      %% No gas figure on the error form, and that is deliberate.
                      %% An exceptional halt consumes the whole allowance of the
                      %% frame it happened in -- INVALID, a jump to a
                      %% non-JUMPDEST, a write in a static frame, an
                      %% out-of-gas condition -- so there is no remainder to
                      %% report. A caller that needs the number derives it: the
                      %% top-level caller charges the full limit, and
                      %% handle_child/7's error clause adds nothing back,
                      %% which is what stops a child that threw from refunding
                      %% gas it never spent. This is also why {revert, ...} is
                      %% a separate case: a revert returns its remainder, since
                      %% the frame unwound normally.
                      {error, R} -> {error, R, Ctx1#ctx.state, E1#e.logs};
                      undefined -> {ok, <<>>, FinalGas, Ctx1#ctx.state, E1#e.logs}
                  end,
            {Res, Ctx1#ctx.transient, Ctx1#ctx.originals}
    catch
        Class:Reason:Stack ->
            {{error, {evm_crash, Class, Reason, hd(Stack)}, State, []}, Transient,
             Originals}
    end.

%% Jump destinations: positions holding JUMPDEST that are not inside PUSH data.
valid_jumpdests(Code) ->
    valid_jumpdests(Code, 0, byte_size(Code), #{}).

valid_jumpdests(_Code, Pos, Size, Acc) when Pos >= Size -> Acc;
valid_jumpdests(Code, Pos, Size, Acc) ->
    case binary:at(Code, Pos) of
        16#5B -> valid_jumpdests(Code, Pos + 1, Size, Acc#{Pos => true});
        Op when Op >= 16#60, Op =< 16#7F ->
            valid_jumpdests(Code, Pos + 1 + (Op - 16#5F), Size, Acc);
        _ -> valid_jumpdests(Code, Pos + 1, Size, Acc)
    end.

%% ---------------------------------------------------------------------------
%% Machine loop
%% ---------------------------------------------------------------------------

exec(E = #e{halt = H}, Ctx) when H =/= undefined -> {E, Ctx};
exec(E = #e{pc = Pc, code = Code}, Ctx) when Pc >= byte_size(Code) ->
    {E#e{halt = stop}, Ctx};
exec(E, Ctx) ->
    Op = binary:at(E#e.code, E#e.pc),
    case eth_fork_schedule:opcode_exists(Op, Ctx#ctx.fork) of
        false -> undefined_opcode(Op, E, Ctx);
        true -> charge_and_run(Op, E, Ctx)
    end.

%% An instruction the executing fork does not have is an exceptional halt, not a
%% cheap one. `do_op/3' would otherwise run it anyway: every clause in this
%% module is unconditional, so PUSH0 executed in a Shanghai block's parent and
%% TSTORE executed anywhere before Cancun, each at a price, each returning a
%% value. The result was a frame that succeeded where the chain's says it must
%% consume its whole allowance -- a different post-state and a different state
%% root, produced without a single error and recorded as a result.
%%
%% `invalid_opcode' is deliberately NOT the reason reported here. That reason
%% belongs to 0xFE, which is a specified instruction at every fork; a byte the
%% fork has never heard of is a different failure and the two are told apart so
%% a caller can.
undefined_opcode(Op, E, Ctx) ->
    {E#e{halt = {error, {undefined_opcode, Op}}}, Ctx}.

%% The price charged before the opcode runs: the part of it that does not depend
%% on what this frame has already touched, taken from eth_fork_schedule.
%%
%% This used to be eth_evm's own table, `base_cost/1', which took no fork and was
%% a second copy of the fork schedule's `base_gas_cost/3'. The two agreed on every
%% opcode's total except four groups, and disagreed on how each total was built:
%% the access opcodes were a warm base here plus a cold surcharge in the handler,
%% while the table returned the whole figure; LOG was a flat 375 here plus 375 a
%% topic in the handler, while the table returned 375 * (topics + 1). Both were
%% internally consistent, which is why neither was wrong on its own and why neither
%% could be substituted for the other. One owner now: the fork table.
%%
%% `constant_cost/2' charges **zero** for the access-sensitive opcodes, because
%% whether a target is warm is not knowable until the handler has looked. Those
%% handlers ask for their whole price instead.
charge_and_run(Op, E, Ctx) ->
    case charge(E, eth_fork_schedule:constant_cost(Op, Ctx#ctx.fork)) of
        {ok, E1} -> do_op(Op, E1, Ctx);
        oog -> oog(E, Ctx)
    end.

next(E, Ctx) -> exec(E#e{pc = E#e.pc + 1}, Ctx).

oog(E, Ctx) -> {E#e{halt = {error, out_of_gas}}, Ctx}.
unsupported(What, E, Ctx) -> {E#e{halt = {error, {unsupported, What}}}, Ctx}.

charge(E, Cost) when E#e.gas >= Cost -> {ok, E#e{gas = E#e.gas - Cost}};
charge(_E, _Cost) -> oog.

add_gas(E, N) -> E#e{gas = E#e.gas + N}.

%% ---------------------------------------------------------------------------
%% Stack / memory helpers
%% ---------------------------------------------------------------------------

push(E, V) -> E#e{stack = [eth_word:mask(V) | E#e.stack]}.

pop(E = #e{stack = [V | R]}) -> {V, E#e{stack = R}}.

popn(E, N) ->
    {lists:sublist(E#e.stack, N), E#e{stack = lists:nthtail(N, E#e.stack)}}.

align32(N) -> ((N + 31) div 32) * 32.

mem_gas(OldSize, NewSize) when NewSize =< OldSize -> 0;
mem_gas(OldSize, NewSize) ->
    OW = (OldSize + 31) div 32,
    NW = (NewSize + 31) div 32,
    (3 * NW + NW * NW div 512) - (3 * OW + OW * OW div 512).

ensure(E, End) ->
    Cur = byte_size(E#e.mem),
    case End =< Cur of
        true -> E;
        false ->
            NewSize = align32(End),
            E#e{mem = <<(E#e.mem)/binary, 0:((NewSize - Cur) * 8)>>}
    end.

charge_mem(E, End) ->
    New = align32(max(End, 0)),
    case charge(E, mem_gas(byte_size(E#e.mem), New)) of
        {ok, E1} -> {ok, ensure(E1, End)};
        oog -> oog
    end.

read(E, Off, Len) -> binary:part(E#e.mem, Off, Len).

write(E, Off, Bin) ->
    Pre = binary:part(E#e.mem, 0, Off),
    PostOff = Off + byte_size(Bin),
    Post = binary:part(E#e.mem, PostOff, byte_size(E#e.mem) - PostOff),
    E#e{mem = <<Pre/binary, Bin/binary, Post/binary>>}.

slice_pad(Bin, Off, Len) ->
    Size = byte_size(Bin),
    case Off >= Size of
        true -> <<0:(Len * 8)>>;
        false ->
            Avail = min(Len, Size - Off),
            Part = binary:part(Bin, Off, Avail),
            <<Part/binary, 0:((Len - Avail) * 8)>>
    end.

%% ---------------------------------------------------------------------------
%% Context accessors
%% ---------------------------------------------------------------------------

s_env(Key, Ctx, Default) -> maps:get(Key, Ctx#ctx.env, Default).
s_msg(Key, Ctx, Default) -> maps:get(Key, Ctx#ctx.msg, Default).

%% ---------------------------------------------------------------------------
%% ---------------------------------------------------------------------------
%% Gas prices live in eth_fork_schedule
%% ---------------------------------------------------------------------------
%%
%% This module used to carry its own copy of the base schedule, `base_cost/1',
%% taking no fork. It is gone, and the fork table now owns every price, because
%% two copies of a consensus constant is one too many and they had already drifted.
%%
%% What the drift cost, measured by evaluating both tables across the whole
%% 0x00-0xFF space at Cancun rather than by reading either:
%%
%%   * The four account accessors and SLOAD returned a warm base of 100 plus a
%%     hardcoded surcharge in the handler -- 2500 for an account, 2000 for a slot
%%     -- so the *pre-Berlin* figures did not exist anywhere in execution. A
%%     Frontier BALANCE cost 2600, where EIP-150 says 400.
%%   * ADDRESS (0x30) had no clause at all and fell to the catch-all, so it cost 3
%%     where it is 2. One gas, on every ADDRESS in every block, and `gasUsed' is a
%%     receipt field. The fork table has 2, so deleting the copy fixed it.
%%   * The CALL family returned 0 here and the whole figure there, because
%%     do_call/3 charged the EIP-2929 access cost itself.
%%   * LOG returned a flat 375 here and 375 * (topics + 1) there, with do_log/3
%%     adding 375 a topic on top of the flat 375. The same total in two
%%     decompositions, and only one of them could be charged by the machine loop.

%% ---------------------------------------------------------------------------
%% Opcode dispatch
%% ---------------------------------------------------------------------------

do_op(Op, E, Ctx) when Op >= 16#60, Op =< 16#7F -> push_n(Op - 16#5F, E, Ctx);
do_op(Op, E, Ctx) when Op >= 16#80, Op =< 16#8F -> dup_n(Op - 16#7F, E, Ctx);
do_op(Op, E, Ctx) when Op >= 16#90, Op =< 16#9F -> swap_n(Op - 16#8F, E, Ctx);
do_op(Op, E, Ctx) when Op >= 16#A0, Op =< 16#A4 -> do_log(Op - 16#A0, E, Ctx);
do_op(16#00, E, Ctx) -> {E#e{halt = stop}, Ctx};

%% arithmetic
do_op(16#01, E, Ctx) -> bin_op(fun eth_word:add/2, E, Ctx);
do_op(16#02, E, Ctx) -> bin_op(fun eth_word:mul/2, E, Ctx);
do_op(16#03, E, Ctx) -> bin_op(fun eth_word:sub/2, E, Ctx);
do_op(16#04, E, Ctx) -> bin_op(fun eth_word:udiv/2, E, Ctx);
do_op(16#05, E, Ctx) -> bin_op(fun eth_word:sdiv/2, E, Ctx);
do_op(16#06, E, Ctx) -> bin_op(fun eth_word:umod/2, E, Ctx);
do_op(16#07, E, Ctx) -> bin_op(fun eth_word:smod/2, E, Ctx);
do_op(16#08, E, Ctx) -> tri_op(fun eth_word:addmod/3, E, Ctx);
do_op(16#09, E, Ctx) -> tri_op(fun eth_word:mulmod/3, E, Ctx);
do_op(16#0A, E, Ctx) ->
    %% EIP-2565: gas accounts for both modulus and exponent sizes,
    %% not just the exponent (avoids undercharging for large moduli).
    {Base, E1} = pop(E), {Exp, E2} = pop(E1),
    Widest = max(byte_size(eth_word:to_bytes(Base)),
                 byte_size(eth_word:to_bytes(Exp))),
    Cost = 10 + 50 * Widest,
    case charge(E2, Cost) of
        {ok, E3} -> next(push(E3, eth_word:exp(Base, Exp)), Ctx);
        oog -> oog(E2, Ctx)
    end;
do_op(16#0B, E, Ctx) ->
    {B, E1} = pop(E), {X, E2} = pop(E1),
    next(push(E2, eth_word:signextend(B, X)), Ctx);

%% comparison / bitwise
do_op(16#10, E, Ctx) -> bin_op(fun eth_word:lt/2, E, Ctx);
do_op(16#11, E, Ctx) -> bin_op(fun eth_word:gt/2, E, Ctx);
do_op(16#12, E, Ctx) -> bin_op(fun eth_word:slt/2, E, Ctx);
do_op(16#13, E, Ctx) -> bin_op(fun eth_word:sgt/2, E, Ctx);
do_op(16#14, E, Ctx) -> bin_op(fun eth_word:eq/2, E, Ctx);
do_op(16#15, E, Ctx) ->
    {A, E1} = pop(E), next(push(E1, eth_word:iszero(A)), Ctx);
do_op(16#16, E, Ctx) -> bin_op(fun eth_word:andb/2, E, Ctx);
do_op(16#17, E, Ctx) -> bin_op(fun eth_word:orb/2, E, Ctx);
do_op(16#18, E, Ctx) -> bin_op(fun eth_word:xorb/2, E, Ctx);
do_op(16#19, E, Ctx) ->
    {A, E1} = pop(E), next(push(E1, eth_word:notb(A)), Ctx);
do_op(16#1A, E, Ctx) -> bin_op(fun eth_word:byte/2, E, Ctx);
do_op(16#1B, E, Ctx) -> shift_op(fun eth_word:shl/2, E, Ctx);
do_op(16#1C, E, Ctx) -> shift_op(fun eth_word:shr/2, E, Ctx);
do_op(16#1D, E, Ctx) -> shift_op(fun eth_word:sar/2, E, Ctx);

%% keccak256
do_op(16#20, E, Ctx) ->
    {Off, E1} = pop(E), {Len, E2} = pop(E1),
    case charge_mem(E2, Off + Len) of
        oog -> oog(E2, Ctx);
        {ok, E3} ->
            Cost = 6 * ((Len + 31) div 32),
            case charge(E3, Cost) of
                {ok, E4} -> next(push(E4, eth_word:from_bytes(eth_keccak:hash(read(E4, Off, Len)))), Ctx);
                oog -> oog(E3, Ctx)
            end
    end;

%% environment
do_op(16#30, E, Ctx) -> next(push(E, eth_word:from_bytes(s_msg(address, Ctx, <<0:160>>))), Ctx);
do_op(16#31, E, Ctx) ->
    {A, E1} = pop(E),
    Addr = eth_state:address(eth_word:to_bytes(A, 20)),
    {Cost, Ctx1} = access_price(Ctx, 16#31, Addr),
    case charge(E1, Cost) of
        oog -> oog(E1, Ctx1);
        {ok, E2} -> next(push(E2, eth_state:balance(Ctx1#ctx.state, Addr)), Ctx1)
    end;
do_op(16#32, E, Ctx) -> next(push(E, eth_word:from_bytes(s_msg(origin, Ctx, <<0:160>>))), Ctx);
do_op(16#33, E, Ctx) -> next(push(E, eth_word:from_bytes(s_msg(caller, Ctx, <<0:160>>))), Ctx);
do_op(16#34, E, Ctx) -> next(push(E, s_msg(value, Ctx, 0)), Ctx);
do_op(16#35, E, Ctx) ->
    {Off, E1} = pop(E),
    Data = s_msg(data, Ctx, <<>>),
    next(push(E1, eth_word:from_bytes(slice_pad(Data, Off, 32))), Ctx);
do_op(16#36, E, Ctx) -> next(push(E, byte_size(s_msg(data, Ctx, <<>>))), Ctx);
do_op(16#37, E, Ctx) ->
    {Dst, E1} = pop(E), {Off, E2} = pop(E1), {Len, E3} = pop(E2),
    case charge_mem(E3, Dst + Len) of
        oog -> oog(E3, Ctx);
        {ok, E4} ->
            Cost = 3 * ((Len + 31) div 32),
            case charge(E4, Cost) of
                {ok, E5} -> next(write(E5, Dst, slice_pad(s_msg(data, Ctx, <<>>), Off, Len)), Ctx);
                oog -> oog(E4, Ctx)
            end
    end;
do_op(16#38, E, Ctx) -> next(push(E, byte_size(E#e.code)), Ctx);
do_op(16#39, E, Ctx) ->
    {Dst, E1} = pop(E), {Off, E2} = pop(E1), {Len, E3} = pop(E2),
    case charge_mem(E3, Dst + Len) of
        oog -> oog(E3, Ctx);
        {ok, E4} ->
            Cost = 3 * ((Len + 31) div 32),
            case charge(E4, Cost) of
                {ok, E5} -> next(write(E5, Dst, slice_pad(E5#e.code, Off, Len)), Ctx);
                oog -> oog(E4, Ctx)
            end
    end;
do_op(16#3A, E, Ctx) -> next(push(E, s_msg(gas_price, Ctx, 0)), Ctx);
do_op(16#3B, E, Ctx) ->
    {A, E1} = pop(E),
    Addr = eth_state:address(eth_word:to_bytes(A, 20)),
    {Cost, Ctx1} = access_price(Ctx, 16#3B, Addr),
    case charge(E1, Cost) of
        oog -> oog(E1, Ctx1);
        {ok, E2} ->
            Code = eth_state:code(Ctx1#ctx.state, Addr),
            next(push(E2, byte_size(Code)), Ctx1)
    end;
do_op(16#3C, E, Ctx) ->
    {A, E1} = pop(E), {Dst, E2} = pop(E1), {Off, E3} = pop(E2), {Len, E4} = pop(E3),
    Addr = eth_state:address(eth_word:to_bytes(A, 20)),
    {Cost, Ctx1} = access_price(Ctx, 16#3C, Addr),
    case charge(E4, Cost) of
        oog -> oog(E4, Ctx1);
        {ok, E5} ->
            case charge_mem(E5, Dst + Len) of
                oog -> oog(E5, Ctx1);
                {ok, E6} ->
                    Cost = 3 * ((Len + 31) div 32),
                    case charge(E6, Cost) of
                        {ok, E7} ->
                            Code = eth_state:code(Ctx1#ctx.state, Addr),
                            next(write(E7, Dst, slice_pad(Code, Off, Len)), Ctx1);
                        oog -> oog(E6, Ctx1)
                    end
            end
    end;
do_op(16#3D, E, Ctx) -> next(push(E, byte_size(E#e.retdata)), Ctx);
do_op(16#3E, E, Ctx) ->
    {Dst, E1} = pop(E), {Off, E2} = pop(E1), {Len, E3} = pop(E2),
    Rd = E3#e.retdata,
    case Off + Len =< byte_size(Rd) of
        false -> {E3#e{halt = {error, returndata_out_of_bounds}}, Ctx};
        true ->
            case charge_mem(E3, Dst + Len) of
                oog -> oog(E3, Ctx);
                {ok, E4} ->
                    Cost = 3 * ((Len + 31) div 32),
                    case charge(E4, Cost) of
                        {ok, E5} -> next(write(E5, Dst, binary:part(Rd, Off, Len)), Ctx);
                        oog -> oog(E4, Ctx)
                    end
            end
    end;
do_op(16#3F, E, Ctx) ->
    {A, E1} = pop(E),
    Addr = eth_state:address(eth_word:to_bytes(A, 20)),
    {Cost, Ctx1} = access_price(Ctx, 16#3F, Addr),
    case charge(E1, Cost) of
        oog -> oog(E1, Ctx1);
        {ok, E2} ->
            Hash = case eth_state:exists(Ctx1#ctx.state, Addr) of
                       true -> eth_word:from_bytes(eth_keccak:hash(eth_state:code(Ctx1#ctx.state, Addr)));
                       false -> 0
                   end,
            next(push(E2, Hash), Ctx1)
    end;

%% block context
do_op(16#40, E, Ctx) ->
    {N, E1} = pop(E),
    Current = s_env(number, Ctx, 0),
    Hash = case N < Current andalso N >= Current - 256 of
               true ->
                   Fun = maps:get(blockhash, Ctx#ctx.env, fun(_) -> undefined end),
                   case Fun(N) of
                       undefined -> 0;
                       H -> eth_word:from_bytes(H)
                   end;
               false -> 0
           end,
    next(push(E1, Hash), Ctx);
do_op(16#41, E, Ctx) -> next(push(E, eth_word:from_bytes(s_env(coinbase, Ctx, <<0:160>>))), Ctx);
do_op(16#42, E, Ctx) -> next(push(E, s_env(timestamp, Ctx, 0)), Ctx);
do_op(16#43, E, Ctx) -> next(push(E, s_env(number, Ctx, 0)), Ctx);
do_op(16#44, E, Ctx) -> next(push(E, s_env(prevrandao, Ctx, 0)), Ctx);
do_op(16#45, E, Ctx) -> next(push(E, s_env(gas_limit, Ctx, 0)), Ctx);
do_op(16#46, E, Ctx) -> next(push(E, s_env(chain_id, Ctx, 1)), Ctx);
do_op(16#47, E, Ctx) ->
    next(push(E, eth_state:balance(Ctx#ctx.state, s_msg(address, Ctx, <<0:160>>))), Ctx);
do_op(16#48, E, Ctx) -> next(push(E, s_env(base_fee, Ctx, 0)), Ctx);
do_op(16#49, E, Ctx) ->
    %% BLOBHASH: no blob index -> versioned-hash mapping is available locally;
    %% fall back to upstream rather than fabricating a zero (which would
    %% silently corrupt any contract branching on blob hashes).
    {_Idx, E1} = pop(E),
    unsupported({opcode, 16#49}, E1, Ctx);
do_op(16#4A, E, Ctx) -> next(push(E, s_env(blob_base_fee, Ctx, 0)), Ctx);

%% stack / memory / storage / flow
do_op(16#50, E, Ctx) -> {_, E1} = pop(E), next(E1, Ctx);
do_op(16#51, E, Ctx) ->
    {Off, E1} = pop(E),
    case charge_mem(E1, Off + 32) of
        oog -> oog(E1, Ctx);
        {ok, E2} -> next(push(E2, eth_word:from_bytes(read(E2, Off, 32))), Ctx)
    end;
do_op(16#52, E, Ctx) ->
    {Off, E1} = pop(E), {Val, E2} = pop(E1),
    case charge_mem(E2, Off + 32) of
        oog -> oog(E2, Ctx);
        {ok, E3} -> next(write(E3, Off, eth_word:to_bytes(Val, 32)), Ctx)
    end;
do_op(16#53, E, Ctx) ->
    {Off, E1} = pop(E), {Val, E2} = pop(E1),
    case charge_mem(E2, Off + 1) of
        oog -> oog(E2, Ctx);
        {ok, E3} -> next(write(E3, Off, <<(Val band 16#FF)>>), Ctx)
    end;
do_op(16#54, E, Ctx) ->
    {Slot, E1} = pop(E),
    Addr = s_msg(address, Ctx, <<0:160>>),
    {Cost, Ctx1} = store_access_price(Ctx, Addr, Slot),
    case charge(E1, Cost) of
        oog -> oog(E1, Ctx1);
        {ok, E2} -> next(push(E2, eth_state:storage(Ctx1#ctx.state, Addr, Slot)), Ctx1)
    end;
do_op(16#55, E, Ctx) ->
    case s_msg(static, Ctx, false) of
        true -> {E#e{halt = {error, write_protection}}, Ctx};
        false ->
            case eth_fork_schedule:sstore_supported(Ctx#ctx.fork) of
                false ->
                    %% **Constantinople only.** The flat rule -- the yellow paper's,
                    %% which Petersburg put back -- is priced at the other eight
                    %% pre-Berlin forks, with EIP-2200's own inherited figures. It is
                    %% EIP-1283 that replaced the rule with net metering, Petersburg
                    %% reverted that, and Constantinople is the one fork left with a
                    %% schedule this module does not implement. `unsupported' is what
                    %% `eth_call' answers with an upstream fallback, so this degrades
                    %% to another node's answer rather than to a plausible wrong one
                    %% of this node's own.
                    unsupported({sstore, Ctx#ctx.fork}, E, Ctx);
                true -> sstore(E, Ctx)
            end
    end;
do_op(16#56, E, Ctx) ->
    {Dest, E1} = pop(E),
    jump(Dest, E1, Ctx);
do_op(16#57, E, Ctx) ->
    {Dest, E1} = pop(E), {Cond, E2} = pop(E1),
    case Cond of
        0 -> next(E2, Ctx);
        _ -> jump(Dest, E2, Ctx)
    end;
do_op(16#58, E, Ctx) -> next(push(E, E#e.pc), Ctx);
do_op(16#59, E, Ctx) -> next(push(E, byte_size(E#e.mem)), Ctx);
do_op(16#5A, E, Ctx) -> next(push(E, E#e.gas), Ctx);
do_op(16#5B, E, Ctx) -> next(E, Ctx);
do_op(16#5C, E, Ctx) ->
    {Slot, E1} = pop(E),
    Addr = s_msg(address, Ctx, <<0:160>>),
    next(push(E1, maps:get({Addr, Slot}, Ctx#ctx.transient, 0)), Ctx);
do_op(16#5D, E, Ctx) ->
    case s_msg(static, Ctx, false) of
        true -> {E#e{halt = {error, write_protection}}, Ctx};
        false ->
            {Slot, E1} = pop(E), {Val, E2} = pop(E1),
            Addr = s_msg(address, Ctx, <<0:160>>),
            T = Ctx#ctx.transient,
            next(E2, Ctx#ctx{transient = T#{{Addr, Slot} => eth_word:mask(Val)}})
    end;
do_op(16#5E, E, Ctx) ->
    {Dst, E1} = pop(E), {Src, E2} = pop(E1), {Len, E3} = pop(E2),
    case charge_mem(E3, max(Dst, Src) + Len) of
        oog -> oog(E3, Ctx);
        {ok, E4} ->
            Cost = 3 * ((Len + 31) div 32),
            case charge(E4, Cost) of
                {ok, E5} ->
                    Bin = read(E5, Src, Len),
                    next(write(E5, Dst, Bin), Ctx);
                oog -> oog(E4, Ctx)
            end
    end;
do_op(16#5F, E, Ctx) -> next(push(E, 0), Ctx);

%% halting / calls
do_op(16#F3, E, Ctx) ->
    {Off, E1} = pop(E), {Len, E2} = pop(E1),
    case charge_mem(E2, Off + Len) of
        oog -> oog(E2, Ctx);
        {ok, E3} -> {E3#e{halt = {return, read(E3, Off, Len)}}, Ctx}
    end;
do_op(16#FD, E, Ctx) ->
    {Off, E1} = pop(E), {Len, E2} = pop(E1),
    case charge_mem(E2, Off + Len) of
        oog -> oog(E2, Ctx);
        {ok, E3} -> {E3#e{halt = {revert, read(E3, Off, Len)}}, Ctx}
    end;
do_op(16#FE, E, Ctx) -> {E#e{halt = {error, invalid_opcode}}, Ctx};
do_op(16#F1, E, Ctx) -> do_call(call, 16#F1, E, Ctx);
do_op(16#F2, E, Ctx) -> do_call(callcode, 16#F2, E, Ctx);
do_op(16#F4, E, Ctx) -> do_call(delegatecall, 16#F4, E, Ctx);
do_op(16#FA, E, Ctx) -> do_call(staticcall, 16#FA, E, Ctx);
do_op(16#F0, E, Ctx) -> do_create(create, E, Ctx);
do_op(16#F5, E, Ctx) -> do_create(create2, E, Ctx);
do_op(16#FF, E, Ctx) ->
    case s_msg(static, Ctx, false) of
        true -> {E#e{halt = {error, write_protection}}, Ctx};
        false ->
            {Ben, E1} = pop(E),
            Addr = s_msg(address, Ctx, <<0:160>>),
            Beneficiary = eth_state:address(eth_word:to_bytes(Ben, 20)),
            State = Ctx#ctx.state,
            State1 = transfer(State, Addr, Beneficiary, eth_state:balance(State, Addr)),
            %% The balance always moves. Whether code and storage are deleted
            %% depends on the fork: before Cancun they always were, and from
            %% EIP-6780 they are only for an account created in this
            %% transaction. The cost is 5000 either way, so this is a question
            %% about what the instruction destroys and not a price -- see
            %% eth_fork_schedule:selfdestruct_deletes/1.
            State2 = case eth_fork_schedule:selfdestruct_deletes(Ctx#ctx.fork)
                          orelse eth_state:is_created(State1, Addr) of
                         true -> eth_state:set_destroyed(State1, Addr);
                         false -> State1
                     end,
            {E1#e{halt = stop}, Ctx#ctx{state = State2}}
    end;

do_op(Op, E, Ctx) -> unsupported({opcode, Op}, E, Ctx).

%% EIP-2200 net metering, with EIP-2929's figures and EIP-3529's refunds.
%%
%% The whole of the previous implementation was a three-case expression over the
%% slot's *current* value, and it was wrong at every fork:
%%
%%   * a no-op write was charged 2900 with a 100 refund, netting 2800, where
%%     EIP-2200 clause (1) charges SLOAD_GAS and nothing else -- 100 from
%%     EIP-2929 -- so 2700 gas net was overcharged on every one of them;
%%   * a dirty write, the case EIP-2200 exists to price, was charged as a clean
%%     one, because nothing distinguished them;
%%   * and the clear refund was 4800 at every fork, EIP-3529's figure, where
%%     before London it is 15000.
sstore(E, Ctx) ->
    {Slot, E1} = pop(E), {Val, E2} = pop(E1),
    Addr = s_msg(address, Ctx, <<0:160>>),
    Current = eth_state:storage(Ctx#ctx.state, Addr, Slot),
    %% EIP-2200 clause (0): at or below the stipend, the frame fails. Checked
    %% before the price, and on the gas as it stands rather than after charging,
    %% which is the whole point -- it exists to stop a frame keeping just enough
    %% gas to keep running but not enough to pay for its own writes.
    case E2#e.gas =< eth_fork_schedule:sstore_sentry(Ctx#ctx.fork) of
        true -> oog(E2, Ctx);
        false ->
            %% EIP-2929's SSTORE clause, in the EIP's own order: check the
            %% `(address, storage_key)' pair against `accessed_storage_keys', charge an
            %% **additional** `COLD_SLOAD_COST' if it is not there, and add it.
            %%
            %% The "additional" was missing. The price came from `sstore_cost/4' -- which
            %% does carry EIP-2929's parameter rewrites, `SLOAD_GAS' -> 100 and
            %% `SSTORE_RESET_GAS' -> 2,900 -- and nothing ever added the 2,100, so
            %% every *first* touch of a slot at Berlin and later cost 2,100 too little
            %% and every second touch was right. That asymmetry is why it survived: a
            %% test that writes a slot twice cannot see it, and the corpus gave it up
            %% only as a -2,100 delta on 40 fixtures, all the same number.
            %%
            %% Marking and charging are one step here, as they are for SLOAD
            %% (`store_access_price/3'): the price depends on the answer and the answer
            %% changes as a side effect of asking, so peeking first is the only order
            %% that gets the second write right.
            {Warm, CtxW} = warm_store(Ctx, Addr, Slot),
            Cold = eth_fork_schedule:sstore_cold_cost(Ctx#ctx.fork, Warm),
            {Original, CtxA} = original_of(CtxW, Addr, Slot, Current),
            {Cost, Refund} = eth_fork_schedule:sstore_cost(
                                Ctx#ctx.fork, Original, Current, Val),
            case charge(E2, Cost + Cold) of
                {ok, E3} ->
                    State1 = eth_state:set_storage(CtxA#ctx.state, Addr, Slot, Val),
                    next(E3#e{refund = E3#e.refund + Refund},
                         CtxA#ctx{state = State1});
                oog -> oog(E2, CtxA)
            end
    end.

%% EIP-2200's `original': the value the slot held when the transaction began.
%%
%% Recorded on the *first* write to the slot, and the read that supplies it is
%% that value because nothing has written the slot yet in this transaction --
%% which is the only reason this is correct and why the record has to happen
%% before the write rather than being read back afterwards. From then on the
%% recorded value is reused, so `Original =/= Current' is exactly EIP-2200's
%% "dirty" test and no separate flag is needed.
%%
%% Note the map this writes to, and note that `mark/2' is the wrong helper here
%% even though it looks like the right one. `mark/2' writes the *transient* set,
%% because a transient write is a flag: an original value is a word, and putting
%% a word into a set of `true' both loses it -- the next SSTORE looks in
%% `originals' and finds nothing -- and leaves a non-`true' value in a map every
%% other reader assumes holds only booleans. It was written against `mark/2'
%% first and every SSTORE was then priced as a first write, so a dirty write cost
%% 2900 where EIP-2200 says 100.
original_of(Ctx, Addr, Slot, Current) ->
    Key = {sstore_original, Addr, Slot},
    case maps:get(Key, Ctx#ctx.originals, absent) of
        absent ->
            {Current, Ctx#ctx{originals = maps:put(Key, Current, Ctx#ctx.originals)}};
        Original ->
            {Original, Ctx}
    end.

%% ---------------------------------------------------------------------------
%% Simple operation helpers
%% ---------------------------------------------------------------------------

bin_op(Fun, E, Ctx) ->
    {A, E1} = pop(E),
    {B, E2} = pop(E1),
    next(push(E2, Fun(A, B)), Ctx).

%% EIP-145 SHL/SHR/SAR: the stack-top is the shift amount and the word BELOW
%% it is the value shifted, so the operand order is the reverse of a regular
%% binop (EIP-145: R = value <<|>> amount).
shift_op(Fun, E, Ctx) ->
    {Amount, E1} = pop(E),
    {Value, E2} = pop(E1),
    next(push(E2, Fun(Value, Amount)), Ctx).

tri_op(Fun, E, Ctx) ->
    {A, E1} = pop(E),
    {B, E2} = pop(E1),
    {C, E3} = pop(E2),
    next(push(E3, Fun(A, B, C)), Ctx).

%% EIP-2929 warm tracking shares the transaction-global transient map under
%% reserved 3-tuple keys (never colliding with {Addr,Slot} TSTORE slots, and
%% inheriting tx scope + revert-discard semantics automatically).
%%
%% Each helper returns the opcode's **whole** price and a context with the
%% account or slot marked warm. Peeking before charging is what makes that
%% possible: the price depends on the answer, and the answer changes as a side
%% effect of asking. Marking first and charging after would charge the cold price
%% to the frame that warmed it, which is the one gas figure EIP-2929 exists to
%% get right.
access_price(Ctx, Op, Addr) ->
    {Warm, Ctx1} = warm_account(Ctx, Addr),
    {eth_fork_schedule:access_cost(Op, Ctx#ctx.fork, #{warm => Warm}), Ctx1}.

store_access_price(Ctx, Addr, Slot) ->
    {Warm, Ctx1} = warm_store(Ctx, Addr, Slot),
    {eth_fork_schedule:access_cost(16#54, Ctx#ctx.fork, #{warm => Warm}), Ctx1}.

warm_account(Ctx, Addr) ->
    case maps:is_key({warm_account, Addr}, Ctx#ctx.transient) of
        true -> {true, Ctx};
        false -> {false, mark({warm_account, Addr}, Ctx)}
    end.

warm_store(Ctx, Addr, Slot) ->
    case maps:is_key({warm_store, Addr, Slot}, Ctx#ctx.transient) of
        true -> {true, Ctx};
        false -> {false, mark({warm_store, Addr, Slot}, Ctx)}
    end.

mark(Key, Ctx) ->
    Ctx#ctx{transient = maps:put(Key, true, Ctx#ctx.transient)}.

push_n(N, E = #e{code = Code, pc = Pc}, Ctx) ->
    Available = max(byte_size(Code) - (Pc + 1), 0),
    Take = min(N, Available),
    Raw = binary:part(Code, Pc + 1, Take),
    Pad = N - Take,
    Val = eth_word:from_bytes(<<Raw/binary, 0:(Pad * 8)>>),
    exec(push(E#e{pc = Pc + 1 + N}, Val), Ctx).

dup_n(N, E, Ctx) ->
    Val = lists:nth(N, E#e.stack),
    next(push(E, Val), Ctx).

swap_n(N, E = #e{stack = [Top | Rest]}, Ctx) ->
    Other = lists:nth(N, Rest),
    Rest1 = lists:sublist(Rest, N - 1) ++ [Top | lists:nthtail(N, Rest)],
    next(E#e{stack = [Other | Rest1]}, Ctx).

jump(Dest, E = #e{dests = Dests}, Ctx) ->
    case maps:is_key(Dest, Dests) andalso Dest < byte_size(E#e.code) of
        true -> exec(E#e{pc = Dest}, Ctx);
        false -> {E#e{halt = {error, {bad_jump, Dest}}}, Ctx}
    end.

do_log(N, E, Ctx) ->
    case s_msg(static, Ctx, false) of
        true -> {E#e{halt = {error, write_protection}}, Ctx};
        false ->
            {Off, E1} = pop(E), {Len, E2} = pop(E1),
            {TopicWords, E3} = popn(E2, N),
            case charge_mem(E3, Off + Len) of
                oog -> oog(E3, Ctx);
                {ok, E4} ->
                    %% The 375 * (topics + 1) is charged by the machine loop, as
                    %% the fork table's constant for LOG_n, so only the per-byte
                    %% term is left. It used to be `375 * N + 8 * Len' here on top
                    %% of a flat 375 in the loop, which is the same total and a
                    %% second decomposition of it -- the reason the loop could not
                    %% simply take the table's figure without this changing too.
                    Cost = 8 * Len,
                    case charge(E4, Cost) of
                        {ok, E5} ->
                            Topics = [eth_word:to_bytes(T, 32) || T <- TopicWords],
                            Addr = s_msg(address, Ctx, <<0:160>>),
                            Log = {Addr, Topics, read(E5, Off, Len)},
                            next(E5#e{logs = E5#e.logs ++ [Log]}, Ctx);
                        oog -> oog(E4, Ctx)
                    end
            end
    end.

%% ---------------------------------------------------------------------------
%% CALL family
%% ---------------------------------------------------------------------------

%% `Kind' says what the call *does* -- whether it moves value, whose storage it
%% runs against -- and `Op' is the opcode, which is what the price is keyed on.
%% Both are needed and they are not the same: DELEGATECALL and STATICCALL are
%% priced as CALL and CALLCODE, and passing a kind-derived guess instead of the
%% byte would put the figure one lookup away from the table that owns it.
do_call(Kind, Op, E, Ctx) ->
    {GasReq, E1} = pop(E),
    {ToW, E2} = pop(E1),
    {Value, E3} = case Kind of
                      call -> pop(E2);
                      callcode -> pop(E2);
                      _ -> {0, E2}
                  end,
    {ArgsOff, E4} = pop(E3),
    {ArgsLen, E5} = pop(E4),
    {RetOff, E6} = pop(E5),
    {RetLen, E7} = pop(E6),
    To = eth_state:address(eth_word:to_bytes(ToW, 20)),
    Static = s_msg(static, Ctx, false),
    case Static andalso Value =/= 0 of
        true -> {E7#e{halt = {error, write_protection}}, Ctx};
        false ->
            %% The whole CALL price in one figure from the fork table: the
            %% EIP-2929 warm/cold access term, plus EIP-161's 9000 for a value
            %% transfer and 25000 for an account that did not exist. The EVM
            %% supplies only the facts -- is the target warm, is value moving,
            %% does the account exist -- and the table supplies the prices,
            %% because the two optional terms are Spurious Dragon's while the
            %% access term is EIP-150's and EIP-2929's.
            %%
            %% The target is warmed by the call itself, for all four kinds.
            {Warm, CtxA} = warm_account(Ctx, To),
            Base = eth_fork_schedule:call_cost(Op, Ctx#ctx.fork,
                                              #{warm => Warm,
                                                value_transfer => Value =/= 0,
                                                new_account => new_account(CtxA, To, Value)}),
            case charge(E7, Base) of
                oog -> oog(E7, CtxA);
                {ok, E8} ->
                    case charge_mem(E8, ArgsOff + ArgsLen) of
                        oog -> oog(E8, CtxA);
                        {ok, E9} ->
                            case charge_mem(E9, RetOff + RetLen) of
                                oog -> oog(E9, CtxA);
                                {ok, E10} ->
                                    Args = read(E10, ArgsOff, ArgsLen),
                                    Avail = E10#e.gas,
                                    case child_gas(GasReq, Avail,
                                                   CtxA#ctx.fork, Value) of
                                        {oog, _Why} ->
                                            oog(E10, CtxA);
                                        {CallGas, _ChildGas} ->
                                            {ok, E11} = charge(E10, CallGas),
                                            run_call(Kind, To, ToW, Value, Args,
                                                     CallGas, RetOff, RetLen,
                                                     E11, CtxA)
                                    end
                            end
                    end
            end
    end.

%% The gas a child frame receives, as `{CallGas, ChildGas}'.
%%
%% `CallGas' is the whole figure and it is what the caller is **charged**, because the
%% caller is refunded exactly `CallGas - Cost' on the way back -- so charging or
%% refunding any other figure hands out or takes back gas nobody paid for. My first
%% version of this change charged the pre-stipend figure and refunded the
%% post-stipend one, and two existing tests caught it at 9300 against 11600.
%%
%% **One figure where the specification has two. Recorded, not shipped.**
%%
%% EIP-150 writes two lines:
%%
%%     gas = min(gas, max_call_gas(compustate.gas - extra_gas))
%%     submsg_gas = gas + opcodes.GSTIPEND * (value > 0)
%%
%% and the spec names both:
%%
%%     call_stipend = Uint(0) if value == 0 else call_stipend
%%     gas = min(gas, max_message_call_gas(gas_left - memory_cost - extra_gas))
%%     return MessageCallGas(gas + extra_gas, gas + call_stipend)
%%
%% so `cost` is the clamped gas **plus `extra_gas`** and `sub_call` is the clamped gas
%% **plus the stipend**. The stipend is in the child's allowance and **not** in the
%% caller's charge. This module returns one number for both, `min(gas + stipend, cap)`,
%% which is the same figure in the other field.
%%
%% Three separate wrong readings of that, all caught, which is why the shape is written
%% down rather than left implicit:
%%
%%   * A `CALL` whose value the caller cannot cover **consumed** its forwarded
%%     allowance. The spec returns it -- `evm.gas_left += message_call_gas.sub_call` --
%%     and the corpus named that as a uniform **+45,247** across the six forks of
%%     `eip2929_gas_cost_increases/test_call_insufficient_balance`. **Fixed**, because
%%     the spec says so in one line and the corpus agrees.
%%   * With the refund in place, the same six fixtures sat at **+2,300**, which is the
%%     stipend exactly -- the consequence of the one-figure model above, and not
%%     independently fixable.
%%   * The first attempt at the split put the stipend in `cost`
%%     (`{Sub + Stipend, Sub}`) rather than in `sub_call`, and the same six fixtures
%%     then charged their **whole 100,000 allowance**: `Sub + 2300` can exceed the gas
%%     remaining and `charge/2' answers `oog'. The error was not a wrong total but a
%%     **halt**, which is much louder than a total and which is the only reason the
%%     mistake is recorded at this length.
%%
%% So the split is not shipped. The residual +2,300 is one gas figure on six fixtures
%% and the fix is a change to **every** value-bearing `CALL`'s accounting, which is not
%% something to ship on the strength of a transcription when the corpus neither
%% confirms nor refutes it. It is named in TASKS.md with the spec text quoted, so the
%% next person does not have to rediscover that the two figures are different.
%%
%% Before Tangerine Whistle there is no cap and no stipend at all. The EIP gives the
%% code it replaced:%% Before Tangerine Whistle there is no cap and no stipend at all. The EIP gives the
%% code it replaced:
%%
%%     if compustate.gas < gas + extra_gas:
%%         return vm_exception('OUT OF GAS', needed=gas+extra_gas)
%%
%% so a call was given whatever the parent had left, and asking for more was an
%% out-of-gas error rather than a clamp. That is a different *answer*, not a different
%% number, which is why it is returned as `{oog, _}' and short-circuits the call
%% rather than being clamped into a smaller frame. An earlier version returned the
%% `oog/2' record from inside an arithmetic expression, which raised `badarith' on
%% every pre-Tangerine call that overran its request.
child_gas(GasReq, Avail, Fork, Value) ->
    case eth_fork_schedule:all_but_one_64th(Fork) of
        true ->
            Stipend = case Value of
                         0 -> 0;
                         _ -> eth_fork_schedule:call_stipend(Fork)
                     end,
            Call = min(GasReq + Stipend, Avail - Avail div 64),
            {Call, Call};
        false ->
            case Avail < GasReq of
                true -> {oog, gas_request_exceeds_remaining};
                false -> {GasReq, GasReq}
            end
    end.


run_call(Kind, To, ToW, Value, Args, CallGas, RetOff, RetLen, E, Ctx) ->
    Env = Ctx#ctx.env,
    Depth = s_msg(depth, Ctx, 0),
    case Depth >= 1024 of
        %% A call that did not happen leaves no return data. This and the two create-side
        %% failures below were the remaining `finish_call/8' sites that left `retdata'
        %% alone, and they are the same defect as the precompile path rather than a
        %% separate one: EIP-211 makes the buffer part of the call's result.
        true -> finish_call(E#e{retdata = <<>>}, Ctx, Ctx#ctx.state, <<>>,
                            RetOff, RetLen, 0);
        false ->
            %% A precompile's identity and price are both fork questions, and the
            %% frame carries the fork in its own record for exactly this. The record
            %% field rather than the Env, because `#ctx.fork' is what the opcode gate
            %% consulted, so the two cannot disagree.
            case eth_evm_precompiles:is_precompile(ToW, Ctx#ctx.fork) of
                true ->
                    %% A precompile's cost is paid out of the gas the CALL
                    %% forwarded, and whatever is left of that forwarded allowance
                    %% returns to the caller. Both halves were wrong.
                    %%
                    %% The cost was charged against the *caller's* remaining gas
                    %% (`charge(E, Cost)'), and the unused forwarded gas was never
                    %% returned at all -- `finish_call/8' discarded its `Left'
                    %% argument, and the regular CALL path does its own refund in
                    %% `handle_child/9', so nothing else did it either. The two
                    %% errors are opposite in direction and both are visible:
                    %%
                    %%   * a CALL forwarding exactly the precompile's cost failed
                    %%     when the caller's own remainder had dipped below that
                    %%     cost -- `charge/2' ran out of gas and the call answered
                    %%     false. Six `eip196_ec_add_mul' fixtures do exactly this,
                    %%     at every fork from Berlin to Prague, and the contract
                    %%     involved forwards 150 gas to a 150-gas ECADD and stores
                    %%     the success flag. It stored 0 where the specification
                    %%     says 1;
                    %%   * and a CALL forwarding *more* than the cost was charged
                    %%     the whole forwarded amount on top of the cost, stranding
                    %%     the remainder. A tight call -- the case where forwarding
                    %%     a specific amount is the whole point -- paid twice.
                    %%
                    %% `CallGas' was already deducted from the caller before
                    %% `run_call/11', so the cost is not charged again here: the net
                    %% effect is that the caller pays exactly `Cost'.
                    From = s_msg(address, Ctx, <<0:160>>),
                    case check_call_value(Kind, Ctx#ctx.state, From, To, Value) of
                        {error, insufficient_balance} ->
                            %% The call cannot happen, and the gas it could not use
                            %% comes **back**. See the note on
                            %% `insufficient_balance_refunds_the_forwarded_gas/0'.
                            finish_call(add_gas(E#e{retdata = <<>>}, CallGas), Ctx,
                                        Ctx#ctx.state, <<>>, RetOff, RetLen, 0);
                        {ok, St0} ->
                            case eth_evm_precompiles:precompile(ToW, Args,
                                                              Ctx#ctx.fork) of
                                {ok, Out, Cost} when CallGas >= Cost ->
                                    %% **`retdata = Out`, and it was missing.**
                                    %% `finish_call/8' does not set it: the caller is
                                    %% responsible, exactly as `handle_child/9' is. So
                                    %% `RETURNDATASIZE' after a **precompile** call
                                    %% reported whatever the *previous* call left, or
                                    %% zero if there had been none.
                                    %%
                                    %% The corpus named it. `test_identity_returndatasize`
                                    %% and `test_warm_coinbase` both end a frame with
                                    %% `CALL; POP; RETURNDATASIZE; PUSH1 k; SSTORE', and
                                    %% the delta is **-19,900** on twenty-four fixtures:
                                    %% 19,900 = `SSTORE_SET_GAS` (20,000) - `SLOAD_GAS`
                                    %% (100), which is the node taking EIP-2200's arm (1.)
                                    %% `current == new' -- because `new' read as 0 -- where
                                    %% the chain takes arm (2.1.1). So it is a **state**
                                    %% defect and not only a gas one: a contract that
                                    %% hashes or compares a precompile's output gets a
                                    %% wrong answer, and the state root is wrong with it.
                                    finish_call(add_gas(E#e{retdata = Out}, CallGas - Cost),
                                                Ctx, St0, Out, RetOff, RetLen, 1);
                                {failed, _Why} ->
                                    %% The precompile ran and its answer is that the
                                    %% call fails: it returns nothing, and the forwarded
                                    %% allowance is consumed -- which it already was,
                                    %% the caller having been charged `CallGas' before
                                    %% the precompile was asked. The caller carries on.
                                    %%
                                    %% `retdata = <<>>' for the same reason the success
                                    %% branch sets it to `Out'. EIP-211 makes the buffer
                                    %% part of the call's *result*, and a result nobody
                                    %% writes is whatever was there before -- which is
                                    %% wrong without looking wrong.
                                    finish_call(E#e{retdata = <<>>}, Ctx, St0, <<>>,
                                                RetOff, RetLen, 0);
                                {ok, _Out, _Cost} ->
                                    %% Not enough forwarded gas for the precompile.
                                    %% The call fails and the whole forwarded
                                    %% allowance is gone -- it was not a CALL frame,
                                    %% so there is nothing to hand the remainder to.
                                    finish_call(E#e{retdata = <<>>}, Ctx, St0, <<>>,
                                                RetOff, RetLen, 0);
                                unsupported ->
                                    unsupported({precompile, ToW}, E, Ctx);
                                {error, Reason} ->
                                    %% A precompile that ran and failed. This is a
                                    %% halt, not a fallback: the EIP says the call
                                    %% fails and the frame's gas is gone. The error
                                    %% form carries no gas figure and nothing is
                                    %% added back, so the whole allowance is
                                    %% consumed -- which is the point. (0x0A is the
                                    %% only precompile that returns this today.)
                                    {E#e{halt = {error, Reason}}, Ctx}
                            end
                    end;
                false ->
                    CurAddr = s_msg(address, Ctx, <<0:160>>),
                    CurCaller = s_msg(caller, Ctx, <<0:160>>),
                    CurValue = s_msg(value, Ctx, 0),
                    {ChildCode, ChildAddr, ChildCaller, ChildValue} =
                        case Kind of
                            call -> {eth_state:code(Ctx#ctx.state, To), To, CurAddr, Value};
                            staticcall -> {eth_state:code(Ctx#ctx.state, To), To, CurAddr, 0};
                            callcode -> {eth_state:code(Ctx#ctx.state, To), CurAddr, CurAddr, Value};
                            delegatecall -> {eth_state:code(Ctx#ctx.state, To), CurAddr, CurCaller, CurValue}
                        end,
                    case check_call_value(Kind, Ctx#ctx.state, CurAddr, To, Value) of
                        {error, insufficient_balance} ->
                            %% Caller cannot cover Value: fail with no state change,
                            %% and hand the forwarded allowance back. The second half is
                            %% the part that was wrong, and it is worth a whole fixture
                            %% file -- see
                            %% `insufficient_balance_refunds_the_forwarded_gas/0'.
                            finish_call(add_gas(E#e{retdata = <<>>}, CallGas), Ctx,
                                        Ctx#ctx.state, <<>>, RetOff, RetLen, 0);
                        {ok, StateIn} ->
                            ChildStatic = Kind =:= staticcall orelse s_msg(static, Ctx, false),
                            ChildMsg = #{address => ChildAddr, caller => ChildCaller,
                                         origin => s_msg(origin, Ctx, <<0:160>>),
                                         value => ChildValue, data => Args,
                                         gas_price => s_msg(gas_price, Ctx, 0),
                                         static => ChildStatic, depth => Depth + 1},
                            {Result, ChildT, ChildO} =
                                run_t(ChildCode, ChildMsg, StateIn, Env, CallGas,
                                      Ctx#ctx.transient, Ctx#ctx.originals,
                                      Ctx#ctx.fork),
                            handle_child(Result, E, Ctx, StateIn, RetOff, RetLen,
                                         ChildT, ChildO)
                    end
            end
    end.

%% `ChildO' -- the child's SSTORE original values -- is taken on **all three**
%% paths, including the two that discard the child's transient writes and state.
%% That is not an oversight and it is not symmetric with `ChildT': an original
%% value belongs to the transaction, not the frame. The child reverting does not
%% un-write the fact that slot 7 held 42 when the transaction started; it only
%% puts the slot back to 42. So the parent's next write to slot 7 must see the
%% same original it would have seen had the child never run.
%%
%% Taking the child's map rather than the parent's is safe because it is always a
%% superset with identical values (see the #ctx{} comment): the child cannot have
%% recorded a *different* original for a key the parent already had.
%%
%% And it is worth being exact about how much this matters, because the paragraph
%% above reads as though discarding the child's map would be a bug. It would not.
%% Dropping it for the parent's on this path was injected and the whole suite
%% stayed green, because a reverted write left the slot at the value the parent's
%% map would have recorded anyway, so the parent's next write re-derives the same
%% original. The child's map is taken because it is a superset and it keeps one
%% rule for all three outcomes instead of three rules -- not because the parent's
%% would be wrong. Stated here so the next reader does not go looking for the bug
%% this is not.
handle_child({ok, Out, Left, St, Logs}, E, Ctx, _StateIn, RetOff, RetLen, ChildT, ChildO) ->
    %% Success commits child state, child logs AND child transient writes
    %% (merged over the parent map: the child ran later).
    MergedT = maps:merge(Ctx#ctx.transient, ChildT),
    E1 = E#e{gas = E#e.gas + Left, retdata = Out, logs = E#e.logs ++ Logs},
    finish_call(E1, Ctx#ctx{state = St, transient = MergedT, originals = ChildO},
                St, Out, RetOff, RetLen, 1);
handle_child({revert, Out, Left, _St, _Logs}, E, Ctx, _StateIn, RetOff, RetLen,
             _ChildT, ChildO) ->
    %% A revert discards the whole child frame INCLUDING the CALL value
    %% transfer: restore the pre-call state, not the post-transfer snapshot.
    %% Child transient writes and logs are discarded with it. Its SSTORE
    %% originals are not, for the reason above.
    Pre = Ctx#ctx.state,
    finish_call(E#e{gas = E#e.gas + Left, retdata = Out},
                Ctx#ctx{state = Pre, originals = ChildO},
                Pre, Out, RetOff, RetLen, 0);
handle_child({error, Reason, _St, _Logs}, E, Ctx, _StateIn, RetOff, RetLen,
             _ChildT, ChildO) ->
    case Reason of
        {unsupported, What} -> unsupported(What, E, Ctx);
        _ -> Pre = Ctx#ctx.state,
             finish_call(E#e{retdata = <<>>}, Ctx#ctx{state = Pre, originals = ChildO},
                         Pre, <<>>, RetOff, RetLen, 0)
    end.

%% Write the (truncated) child output to memory, push success flag.
%% The child's unused gas used to be an eighth argument here, named `Left', and
%% was discarded -- `_Left'. It read as load-bearing and was not: the regular CALL
%% path does its own refund in `handle_child/9' (`E#e{gas = E#e.gas + Left}') and
%% passes nothing here, so no regular call ever read it.
%%
%% Meanwhile the precompile path *did* pass a refund in and received nothing back,
%% because this function dropped it. So the one argument every regular call ignored
%% was the only thing the precompile path was relying on, which is how a tight call
%% to a precompile could be charged for gas nobody received. The parameter is gone
%% rather than renamed: a refund belongs where the child frame's result is, and
%% there is exactly one of those.
finish_call(E, Ctx, State, Out, RetOff, RetLen, Success) ->
    CopyLen = min(RetLen, byte_size(Out)),
    OutBin = binary:part(Out, 0, CopyLen),
    E1 = case RetLen > 0 andalso CopyLen > 0 of
             true -> write(E, RetOff, OutBin);
             false -> E
         end,
    next(push(E1, Success), Ctx#ctx{state = State}).

%% EIP-161's 25000 applies to a value-bearing call whose destination does not
%% exist, and to nothing else. The *price* is the fork table's; this is only the
%% fact, and a zero-value call answers false without reading the account at all --
%% which is both correct and the reason a read-only call cannot be charged for
%% creating something it cannot create.
new_account(_Ctx, _To, 0) -> false;
new_account(Ctx, To, _Value) ->
    not eth_state:exists(Ctx#ctx.state, To).

transfer(State, _From, _To, 0) -> State;
transfer(State, From, To, Value) ->
    FromBal = eth_state:balance(State, From),
    ToBal = eth_state:balance(State, To),
    S1 = eth_state:set_balance(State, From, FromBal - Value),
    eth_state:set_balance(S1, To, ToBal + Value).

%% A CALL moves value before execution; staticcall/delegatecall/callcode do
%% not move value out of the caller (callcode's net effect is zero, so doing
%% nothing matches). A caller that cannot cover Value fails the call with no
%% state change (mirrors the depth-limit failure shape).
check_call_value(Kind, State, _From, _To, 0) when Kind =:= call; Kind =:= callcode ->
    %% Zero value moves nothing: skip the balance read entirely (also keeps
    %% view-only calls free of upstream fetches).
    {ok, State};
check_call_value(Kind, State, From, To, Value) when Kind =:= call; Kind =:= callcode ->
    case can_transfer(State, From, Value) of
        true -> {ok, transfer(State, From, To, Value)};
        false -> {error, insufficient_balance}
    end;
check_call_value(_Kind, State, _From, _To, _Value) ->
    {ok, State}.

%% **A `CALL` whose value the caller cannot cover returns its forwarded gas.**
%%
%% The spec's own `call`, in `forks/berlin/vm/instructions/system.py`:
%%
%%     sender_balance = get_account(evm.message.tx_env.state,
%%                                 evm.message.current_target).balance
%%     if sender_balance < value:
%%         push(evm.stack, U256(0))
%%         evm.return_data = b""
%%         evm.gas_left += message_call_gas.sub_call
%%     else:
%%         generic_call(...)
%%
%% Three things, and the node had the first and none of the others: the call fails
%% (pushing 0), the return data is emptied, and `sub_call` is added back. This module
%% pushed 0 and **consumed** the forwarded allowance, on the reasoning -- recorded in a
%% comment here until now -- that "the CALL opcode has already paid for it". The
%% opcode has paid for `sub_call`; it is `sub_call` that is being refunded, which is a
%% different direction of travel and not a consequence of the same fact.
%%
%% The corpus named it as a uniform **+45,247** across six forks of
%% `eip2929_gas_cost_increases/test_call_insufficient_balance`, whose contract forwards
%% `GAS` with a value of 1 from an account holding 0, so `sub_call` is essentially the
%% whole allowance. Positive delta, node charges more -- consistent with consuming a
%% refund the chain makes.
%%
%% `callcode` is here for the same reason and was **not** before: the spec's `callcode`
%% is byte-for-byte the same block, with the same `sender_balance` check and the same
%% `evm.gas_left += message_call_gas.sub_call`, and this module's `check_call_value/5`
%% only had a `call` clause. So `CALLCODE` transferred no value and consulted no
%% balance. `delegatecall` and `staticcall` correctly have neither, the spec passing
%% `should_transfer_value=False` and `value=U256(0)` for them.

can_transfer(_State, _From, 0) -> true;
can_transfer(State, From, Value) ->
    eth_state:balance(State, From) >= Value.

%% ---------------------------------------------------------------------------
%% CREATE / CREATE2
%% ---------------------------------------------------------------------------

do_create(Op, E, Ctx) ->
    case s_msg(static, Ctx, false) of
        true -> {E#e{halt = {error, write_protection}}, Ctx};
        false ->
            {Value, E1} = pop(E), {Off, E2} = pop(E1), {Len, E3} = pop(E2),
            {Salt, E4} = case Op of
                             create2 -> pop(E3);
                             _ -> {0, E3}
                         end,
            case charge_mem(E4, Off + Len) of
                oog -> oog(E4, Ctx);
                {ok, E5} ->
                    %% EIP-3860 (Shanghai) charges both creators 2 gas per
                    %% 32-byte word of init code, to put a price on the work a
                    %% large init code can force before it runs a single
                    %% instruction. CREATE2 additionally hashes the init code at
                    %% KECCAK256's 6 per word, so it pays 8 where CREATE pays 2.
                    %%
                    %% Neither term was charged here: do_create/3 billed CREATE2's
                    %% hashing and nothing for CREATE at all. So deploying a large
                    %% contract -- which then gets to execute init code whose
                    %% hashing the block has already paid for -- was free, and
                    %% CREATE2 was undercharged by two thirds.
                    %%
                    %% Charged unconditionally, because this module has no fork and
                    %% applies one schedule to every block; the Shanghai condition
                    %% belongs with the per-fork branching that is still missing.
                    Words = (Len + 31) div 32,
                    Extra = case Op of
                                create2 -> 8 * Words;
                                _ -> 2 * Words
                            end,
                    case charge(E5, Extra) of
                        oog -> oog(E5, Ctx);
                        {ok, E6} ->
                            Init = read(E6, Off, Len),
                            run_create(Op, Init, Salt, Value, E6, Ctx)
                    end
            end
    end.

run_create(Op, Init, Salt, Value, E, Ctx) ->
    case s_msg(depth, Ctx, 0) >= 1024 of
        true ->
            finish_call(E#e{retdata = <<>>}, Ctx, Ctx#ctx.state, <<>>, 0, 0, 0);
        false ->
            run_create1(Op, Init, Salt, Value, E, Ctx)
    end.

run_create1(Op, Init, Salt, Value, E, Ctx) ->
    Sender = s_msg(address, Ctx, <<0:160>>),
    Nonce = eth_state:nonce(Ctx#ctx.state, Sender),
    State1 = eth_state:set_nonce(Ctx#ctx.state, Sender, Nonce + 1),
    NewAddr = create_address(Op, Sender, Nonce, Salt, Init),
    case eth_state:exists(State1, NewAddr) of
        true ->
            finish_call(E#e{retdata = <<>>}, Ctx#ctx{state = State1},
                        State1, <<>>, 0, 0, 0);
        false ->
            Avail = E#e.gas,
            %% "CREATE only provides all but one 64th of the parent gas to the child
            %% call." -- EIP-150, and before Tangerine Whistle it provided all of it,
            %% like every other call.
            ChildGas = case eth_fork_schedule:all_but_one_64th(Ctx#ctx.fork) of
                          true -> Avail - Avail div 64;
                          false -> Avail
                      end,
            {ok, E1} = charge(E, ChildGas),
            case can_transfer(State1, Sender, Value) of
                false ->
                    %% Nonce stays consumed (as in geth); no value moves.
                    finish_call(E1#e{retdata = <<>>}, Ctx, State1, <<>>, 0, 0, 0);
                true ->
                    create_with_value(Op, Init, Value, Sender, NewAddr, State1, E1, Ctx, ChildGas)
            end
    end.

create_with_value(_Op, Init, Value, Sender, NewAddr, State1, E1, Ctx, ChildGas) ->
    State2 = transfer(State1, Sender, NewAddr, Value),
    Env = Ctx#ctx.env,
    ChildMsg = #{address => NewAddr, caller => Sender,
                 origin => s_msg(origin, Ctx, <<0:160>>),
                 value => Value, data => <<>>,
                 gas_price => s_msg(gas_price, Ctx, 0),
                 static => false, depth => s_msg(depth, Ctx, 0) + 1},
    Result = run_t(Init, ChildMsg, State2, Env, ChildGas, Ctx#ctx.transient,
                   Ctx#ctx.originals, Ctx#ctx.fork),
    case Result of
        {{ok, Code, Left, St, Logs}, ChildT, ChildO} ->
            %% **The code-deposit cost was not charged here at all.** Not the 200 per
            %% byte of the returned code, and not the EIP-170 size cap -- that one was
            %% a bare `byte_size(Code) =< 24576' in a guard, so it held at every fork
            %% and was measured in the wrong unit: it was a *predicate* with no price
            %% behind it. The consequence is that this node deploys code of any size
            %% for free, and never goes out of gas on a create whose deposit it cannot
            %% pay.
            %%
            %% The corpus caught it, and the arithmetic is what makes it certain rather
            %% than likely. `create/test_create_deposit_oog` has a twenty-three-byte
            %% callee that stores a word, then `CREATE`s six bytes of init code which
            %% itself `RETURN`s 10,000 bytes -- so the deposit is 200 x 10,000 =
            %% 2,000,000 gas against a 934,172-gas frame. Seven of those fixtures
            %% expected the **whole** 1,000,000 allowance to be spent and this node
            %% spent 57,062, handing back 918,145 that the chain never returns. The
            %% 200 is the yellow paper's `G_codedeposit' and no EIP has changed it;
            %% what EIP-2 changed is the *consequence*, quoted in `code_deposit_cost/1'.
            %%
            %% Three ways to fail, and they are three different rules:
            %%
            %%   * cannot pay the deposit (Homestead+, EIP-2 item 3) -- the create goes
            %%     out of gas and **all** the forwarded gas is gone, which is what
            %%     `{{error, _, _, _}}' already means everywhere else in this module.
            %%   * code over `max_code_size/1' (Spurious Dragon+, EIP-170) -- "contract
            %%     creation fails with an out of gas error", so the same thing. The
            %%     cap did not exist before Spurious Dragon, so below it a deployment
            %%     is bounded only by what the caller can pay.
            %%   * neither -- deploy, charging `Left' back less the deposit.
            Size = byte_size(Code),
            Deposit = eth_fork_schedule:code_deposit_cost(Ctx#ctx.fork) * Size,
            case {E1#e.gas + Left < Deposit,
                  eth_fork_schedule:max_code_size(Ctx#ctx.fork) < Size} of
                {true, _} ->
                    %% Out of gas paying the deposit. Nothing is added back, so the
                    %% frame's entire forwarded allowance is consumed -- which is the
                    %% rule a frame that halts has always had here, and the one EIP-2
                    %% says applies to the deposit. No deployment, no value movement
                    %% (State1 has the nonce and nothing else), and the init code's
                    %% SSTORE originals are kept: the code ran, so the facts it
                    %% recorded are transaction facts whatever became of the
                    %% deployment.
                    next(push(E1#e{retdata = <<>>}, 0),
                         Ctx#ctx{state = State1, originals = ChildO});
                {_, true} ->
                    %% EIP-170's size cap. Same accounting -- the forwarded allowance
                    %% is gone -- and same state. It is a separate clause only because
                    %% before Spurious Dragon this branch is unreachable, so the two
                    %% rules do not exist at the same time at any one fork.
                    next(push(E1#e{retdata = <<>>}, 0),
                         Ctx#ctx{state = State1, originals = ChildO});
                {false, false} ->
                    St1 = eth_state:set_code(St, NewAddr, Code),
                    %% Record the creation for EIP-6780 (same-tx self-destruct).
                    St2 = eth_state:mark_created(St1, NewAddr),
                    MergedT = maps:merge(Ctx#ctx.transient, ChildT),
                    E2 = E1#e{gas = E1#e.gas + Left - Deposit,
                              logs = E1#e.logs ++ Logs,
                              %% **`retdata = <<>>`, on success as well as on failure.**
                              %% The specification is explicit:
                              %%
                              %%     incorporate_child_on_success(evm, child_evm)
                              %%     evm.return_data = b""
                              %%     push(evm.stack, U256.from_be_bytes(
                              %%         child_evm.message.current_target))
                              %%
                              %% (`execution-specs', `forks/cancun/vm/instructions/
                              %% system.py'.) The **stack** receives the address; the
                              %% buffer receives nothing. This is the one `retdata' site
                              %% a grep for `finish_call(' cannot find, because the
                              %% success path pushes the address itself rather than
                              %% going through `finish_call/8' -- so a contract reading
                              %% `RETURNDATASIZE' after deploying a contract saw the
                              %% size of whatever it had called before.
                              %%
                              %% An earlier reading of EIP-211 -- that the created
                              %% address is left in the buffer, 32 bytes left-padded --
                              %% is wrong for the current specification. It was read
                              %% from the EIP rather than recalled, and it is written
                              %% down here because it is a plausible mistake rather than
                              %% an arbitrary one.
                              retdata = <<>>},
                    next(push(E2, eth_word:from_bytes(NewAddr)),
                         Ctx#ctx{state = St2, transient = MergedT, originals = ChildO})
            end;
        {{revert, Out, Left, _St, _}, _ChildT, ChildO} ->
            %% Revert rolls back deployment AND the value transfer; the
            %% sender nonce increment (State1) is kept. The init code's SSTORE
            %% originals are kept with it, for the same reason a reverted CALL's
            %% are: they are transaction facts, not frame ones.
            next(push(E1#e{gas = E1#e.gas + Left, retdata = Out}, 0),
                 Ctx#ctx{state = State1, originals = ChildO});
        {{error, Reason, _St, _}, _ChildT, _ChildO} ->
            case Reason of
                {unsupported, What} -> unsupported(What, E1, Ctx);
                _ -> next(push(E1#e{retdata = <<>>}, 0), Ctx#ctx{state = State1})
            end
    end.

create_address(create, Sender, Nonce, _Salt, _Init) ->
    Enc = eth_rlp:encode([Sender, Nonce]),
    <<_:12/binary, Addr:20/binary>> = eth_keccak:hash(Enc),
    Addr;
create_address(create2, Sender, _Nonce, Salt, Init) ->
    InitHash = eth_keccak:hash(Init),
    <<_:12/binary, Addr:20/binary>> =
        eth_keccak:hash(<<16#FF, Sender/binary, (eth_word:to_bytes(Salt, 32))/binary,
                         InitHash/binary>>),
    Addr.
