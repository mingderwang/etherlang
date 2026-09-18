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

-record(ctx, {state, env, msg, transient = #{}}).

-export([run/5, valid_jumpdests/1]).

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------
%% run(Code, Msg, State, Env, Gas) ->
%%   {ok, Output, GasLeft, State, Logs}
%% | {revert, Output, GasLeft, State, Logs}
%% | {error, Reason, State, Logs}
run(Code, Msg, State, Env, Gas) when is_binary(Code) ->
    Ctx = #ctx{state = State, env = Env, msg = Msg},
    E0 = #e{code = Code, gas = max(Gas, 0), dests = valid_jumpdests(Code)},
    try exec(E0, Ctx) of
        {E1, Ctx1} ->
            case E1#e.halt of
                {return, Out} -> {ok, Out, E1#e.gas, Ctx1#ctx.state, E1#e.logs};
                stop -> {ok, <<>>, E1#e.gas, Ctx1#ctx.state, E1#e.logs};
                {revert, Out} -> {revert, Out, E1#e.gas, Ctx1#ctx.state, E1#e.logs};
                {error, R} -> {error, R, Ctx1#ctx.state, E1#e.logs};
                undefined -> {ok, <<>>, E1#e.gas, Ctx1#ctx.state, E1#e.logs}
            end
    catch
        Class:Reason:Stack ->
            {error, {evm_crash, Class, Reason, hd(Stack)}, State, []}
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
    case charge(E, base_cost(Op)) of
        {ok, E1} -> do_op(Op, E1, Ctx);
        oog -> oog(E, Ctx)
    end.

next(E, Ctx) -> exec(E#e{pc = E#e.pc + 1}, Ctx).

oog(E, Ctx) -> {E#e{halt = {error, out_of_gas}}, Ctx}.
unsupported(What, E, Ctx) -> {E#e{halt = {error, {unsupported, What}}}, Ctx}.

charge(E, Cost) when E#e.gas >= Cost -> {ok, E#e{gas = E#e.gas - Cost}};
charge(_E, _Cost) -> oog.

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
%% Base gas schedule (approximate)
%% ---------------------------------------------------------------------------

base_cost(16#00) -> 0;
base_cost(16#02) -> 5;
base_cost(16#04) -> 5;
base_cost(16#05) -> 5;
base_cost(16#06) -> 5;
base_cost(16#07) -> 5;
base_cost(16#08) -> 8;
base_cost(16#09) -> 8;
base_cost(16#0A) -> 10;
base_cost(16#0B) -> 5;
base_cost(Op) when Op >= 16#01, Op =< 16#1D -> 3;
base_cost(16#20) -> 30;
base_cost(16#31) -> 2600;
base_cost(16#32) -> 2;
base_cost(16#33) -> 2;
base_cost(16#34) -> 2;
base_cost(16#35) -> 3;
base_cost(16#36) -> 2;
base_cost(16#37) -> 3;
base_cost(16#38) -> 2;
base_cost(16#39) -> 3;
base_cost(16#3A) -> 2;
base_cost(16#3B) -> 2600;
base_cost(16#3C) -> 2600;
base_cost(16#3D) -> 2;
base_cost(16#3E) -> 3;
base_cost(16#3F) -> 2600;
base_cost(16#40) -> 20;
base_cost(Op) when Op >= 16#41, Op =< 16#46 -> 2;
base_cost(16#47) -> 5;
base_cost(16#48) -> 2;
base_cost(16#49) -> 3;
base_cost(16#4A) -> 2;
base_cost(16#50) -> 2;
base_cost(16#51) -> 3;
base_cost(16#52) -> 3;
base_cost(16#53) -> 3;
base_cost(16#54) -> 2100;
base_cost(16#55) -> 0;
base_cost(16#56) -> 8;
base_cost(16#57) -> 10;
base_cost(16#58) -> 2;
base_cost(16#59) -> 2;
base_cost(16#5A) -> 2;
base_cost(16#5B) -> 1;
base_cost(16#5C) -> 100;
base_cost(16#5D) -> 100;
base_cost(16#5E) -> 3;
base_cost(16#5F) -> 2;
base_cost(Op) when Op >= 16#60, Op =< 16#7F -> 3;
base_cost(Op) when Op >= 16#80, Op =< 16#8F -> 3;
base_cost(Op) when Op >= 16#90, Op =< 16#9F -> 3;
base_cost(Op) when Op >= 16#A0, Op =< 16#A4 -> 375;
base_cost(16#F0) -> 32000;
base_cost(16#F5) -> 32000;
base_cost(16#FF) -> 5000;
base_cost(_) -> 3.

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
    {Base, E1} = pop(E), {Exp, E2} = pop(E1),
    Cost = 10 + 50 * byte_size(eth_word:to_bytes(Exp)),
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
do_op(16#1B, E, Ctx) -> bin_op(fun eth_word:shl/2, E, Ctx);
do_op(16#1C, E, Ctx) -> bin_op(fun eth_word:shr/2, E, Ctx);
do_op(16#1D, E, Ctx) -> bin_op(fun eth_word:sar/2, E, Ctx);

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
    next(push(E1, eth_state:balance(Ctx#ctx.state, Addr)), Ctx);
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
    Code = eth_state:code(Ctx#ctx.state, eth_state:address(eth_word:to_bytes(A, 20))),
    next(push(E1, byte_size(Code)), Ctx);
do_op(16#3C, E, Ctx) ->
    {A, E1} = pop(E), {Dst, E2} = pop(E1), {Off, E3} = pop(E2), {Len, E4} = pop(E3),
    case charge_mem(E4, Dst + Len) of
        oog -> oog(E4, Ctx);
        {ok, E5} ->
            Cost = 3 * ((Len + 31) div 32),
            case charge(E5, Cost) of
                {ok, E6} ->
                    Code = eth_state:code(Ctx#ctx.state, eth_state:address(eth_word:to_bytes(A, 20))),
                    next(write(E6, Dst, slice_pad(Code, Off, Len)), Ctx);
                oog -> oog(E5, Ctx)
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
    Hash = case eth_state:exists(Ctx#ctx.state, Addr) of
               true -> eth_word:from_bytes(eth_keccak:hash(eth_state:code(Ctx#ctx.state, Addr)));
               false -> 0
           end,
    next(push(E1, Hash), Ctx);

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
    {_Idx, E1} = pop(E),
    next(push(E1, 0), Ctx);
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
    next(push(E1, eth_state:storage(Ctx#ctx.state, Addr, Slot)), Ctx);
do_op(16#55, E, Ctx) ->
    case s_msg(static, Ctx, false) of
        true -> {E#e{halt = {error, write_protection}}, Ctx};
        false ->
            {Slot, E1} = pop(E), {Val, E2} = pop(E1),
            Addr = s_msg(address, Ctx, <<0:160>>),
            Current = eth_state:storage(Ctx#ctx.state, Addr, Slot),
            Cost = case Current =:= 0 andalso Val =/= 0 of
                       true -> 20000;
                       false -> 2900
                   end,
            case charge(E2, Cost) of
                {ok, E3} ->
                    State1 = eth_state:set_storage(Ctx#ctx.state, Addr, Slot, Val),
                    next(E3, Ctx#ctx{state = State1});
                oog -> oog(E2, Ctx)
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
do_op(16#F1, E, Ctx) -> do_call(call, E, Ctx);
do_op(16#F2, E, Ctx) -> do_call(callcode, E, Ctx);
do_op(16#F4, E, Ctx) -> do_call(delegatecall, E, Ctx);
do_op(16#FA, E, Ctx) -> do_call(staticcall, E, Ctx);
do_op(16#F0, E, Ctx) -> do_create(create, E, Ctx);
do_op(16#F5, E, Ctx) -> do_create(create2, E, Ctx);
do_op(16#FF, E, Ctx) ->
    case s_msg(static, Ctx, false) of
        true -> {E#e{halt = {error, write_protection}}, Ctx};
        false ->
            {Ben, E1} = pop(E),
            Addr = s_msg(address, Ctx, <<0:160>>),
            Beneficiary = eth_state:address(eth_word:to_bytes(Ben, 20)),
            State1 = transfer(Ctx#ctx.state, Addr, Beneficiary, eth_state:balance(Ctx#ctx.state, Addr)),
            {E1#e{halt = stop}, Ctx#ctx{state = State1}}
    end;

do_op(Op, E, Ctx) -> unsupported({opcode, Op}, E, Ctx).

%% ---------------------------------------------------------------------------
%% Simple operation helpers
%% ---------------------------------------------------------------------------

bin_op(Fun, E, Ctx) ->
    {A, E1} = pop(E),
    {B, E2} = pop(E1),
    next(push(E2, Fun(A, B)), Ctx).

tri_op(Fun, E, Ctx) ->
    {A, E1} = pop(E),
    {B, E2} = pop(E1),
    {C, E3} = pop(E2),
    next(push(E3, Fun(A, B, C)), Ctx).

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
                    Cost = 375 * N + 8 * Len,
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

do_call(Kind, E, Ctx) ->
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
            Base = 2600 + value_cost(Value) + new_account_cost(Ctx, To, Value),
            case charge(E7, Base) of
                oog -> oog(E7, Ctx);
                {ok, E8} ->
                    case charge_mem(E8, ArgsOff + ArgsLen) of
                        oog -> oog(E8, Ctx);
                        {ok, E9} ->
                            case charge_mem(E9, RetOff + RetLen) of
                                oog -> oog(E9, Ctx);
                                {ok, E10} ->
                                    Args = read(E10, ArgsOff, ArgsLen),
                                    Avail = E10#e.gas,
                                    CallGas = min(GasReq, Avail - Avail div 64),
                                    {ok, E11} = charge(E10, CallGas),
                                    run_call(Kind, To, ToW, Value, Args, CallGas,
                                             RetOff, RetLen, E11, Ctx)
                            end
                    end
            end
    end.

run_call(Kind, To, ToW, Value, Args, CallGas, RetOff, RetLen, E, Ctx) ->
    Env = Ctx#ctx.env,
    Depth = s_msg(depth, Ctx, 0),
    case Depth >= 1024 of
        true -> finish_call(E, Ctx, Ctx#ctx.state, <<>>, RetOff, RetLen, 0, 0);
        false ->
            case eth_evm_precompiles:is_precompile(ToW) of
                true ->
                    case eth_evm_precompiles:precompile(ToW, Args) of
                        {ok, Out, Cost} ->
                            case charge(E, Cost) of
                                {ok, E1} -> finish_call(E1, Ctx, Ctx#ctx.state, Out, RetOff, RetLen, 1, E1#e.gas);
                                oog -> finish_call(E, Ctx, Ctx#ctx.state, <<>>, RetOff, RetLen, 0, 0)
                            end;
                        unsupported ->
                            unsupported({precompile, ToW}, E, Ctx)
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
                    StateIn = case Kind of
                                  call -> transfer(Ctx#ctx.state, CurAddr, To, Value);
                                  _ -> Ctx#ctx.state
                              end,
                    ChildStatic = Kind =:= staticcall orelse s_msg(static, Ctx, false),
                    ChildMsg = #{address => ChildAddr, caller => ChildCaller,
                                 origin => s_msg(origin, Ctx, <<0:160>>),
                                 value => ChildValue, data => Args,
                                 gas_price => s_msg(gas_price, Ctx, 0),
                                 static => ChildStatic, depth => Depth + 1},
                    Result = run(ChildCode, ChildMsg, StateIn, Env, CallGas),
                    handle_child(Result, E, Ctx, StateIn, RetOff, RetLen)
            end
    end.

handle_child({ok, Out, Left, St, _Logs}, E, Ctx, _StateIn, RetOff, RetLen) ->
    finish_call(E#e{gas = E#e.gas + Left, retdata = Out}, Ctx, St, Out, RetOff, RetLen, 1, Left);
handle_child({revert, Out, Left, _St, _Logs}, E, Ctx, StateIn, RetOff, RetLen) ->
    finish_call(E#e{gas = E#e.gas + Left, retdata = Out}, Ctx#ctx{state = StateIn},
                StateIn, Out, RetOff, RetLen, 0, Left);
handle_child({error, Reason, _St, _Logs}, E, Ctx, StateIn, RetOff, RetLen) ->
    case Reason of
        {unsupported, What} -> unsupported(What, E, Ctx);
        _ -> finish_call(E#e{retdata = <<>>}, Ctx#ctx{state = StateIn},
                         StateIn, <<>>, RetOff, RetLen, 0, 0)
    end.

%% Write the (truncated) child output to memory, push success flag.
finish_call(E, Ctx, State, Out, RetOff, RetLen, Success, _Left) ->
    CopyLen = min(RetLen, byte_size(Out)),
    OutBin = binary:part(Out, 0, CopyLen),
    E1 = case RetLen > 0 andalso CopyLen > 0 of
             true -> write(E, RetOff, OutBin);
             false -> E
         end,
    next(push(E1, Success), Ctx#ctx{state = State}).

value_cost(0) -> 0;
value_cost(_) -> 9000.

new_account_cost(Ctx, To, Value) when Value > 0 ->
    case eth_state:exists(Ctx#ctx.state, To) of
        true -> 0;
        false -> 25000
    end;
new_account_cost(_Ctx, _To, _Value) -> 0.

transfer(State, _From, _To, 0) -> State;
transfer(State, From, To, Value) ->
    FromBal = eth_state:balance(State, From),
    ToBal = eth_state:balance(State, To),
    S1 = eth_state:set_balance(State, From, FromBal - Value),
    eth_state:set_balance(S1, To, ToBal + Value).

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
                    Extra = case Op of
                                create2 -> 6 * ((Len + 31) div 32);
                                _ -> 0
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
            finish_call(E, Ctx, Ctx#ctx.state, <<>>, 0, 0, 0, 0);
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
                        State1, <<>>, 0, 0, 0, 0);
        false ->
            Avail = E#e.gas,
            ChildGas = Avail - Avail div 64,
            {ok, E1} = charge(E, ChildGas),
            State2 = transfer(State1, Sender, NewAddr, Value),
            Env = Ctx#ctx.env,
            ChildMsg = #{address => NewAddr, caller => Sender,
                         origin => s_msg(origin, Ctx, <<0:160>>),
                         value => Value, data => <<>>,
                         gas_price => s_msg(gas_price, Ctx, 0),
                         static => false, depth => s_msg(depth, Ctx, 0) + 1},
            Result = run(Init, ChildMsg, State2, Env, ChildGas),
            case Result of
                {ok, Code, Left, St, _} when byte_size(Code) =< 24576 ->
                    St1 = eth_state:set_code(St, NewAddr, Code),
                    next(push(E1#e{gas = E1#e.gas + Left}, eth_word:from_bytes(NewAddr)),
                         Ctx#ctx{state = St1});
                {ok, _Code, _Left, St, _} ->
                    %% code too large: consume gas, fail
                    next(push(E1#e{gas = E1#e.gas, retdata = <<>>}, 0), Ctx#ctx{state = St});
                {revert, Out, Left, _St, _} ->
                    next(push(E1#e{gas = E1#e.gas + Left, retdata = Out}, 0),
                         Ctx#ctx{state = State2});
                {error, Reason, _St, _} ->
                    case Reason of
                        {unsupported, What} -> unsupported(What, E1, Ctx);
                        _ -> next(push(E1#e{retdata = <<>>}, 0), Ctx#ctx{state = State2})
                    end
            end
    end.

create_address(create, Sender, Nonce, _Salt, _Init) ->
    Enc = eth_rlp:encode([Sender, Nonce]),
    <<_:24/binary, Addr:20/binary>> = eth_keccak:hash(Enc),
    Addr;
create_address(create2, Sender, _Nonce, Salt, Init) ->
    InitHash = eth_keccak:hash(Init),
    <<_:24/binary, Addr:20/binary>> =
        eth_keccak:hash(<<16#FF, Sender/binary, (eth_word:to_bytes(Salt, 32))/binary,
                         InitHash/binary>>),
    Addr.
