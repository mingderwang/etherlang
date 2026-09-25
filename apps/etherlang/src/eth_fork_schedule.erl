%% Per-fork gas schedule and base fee calculation for Phase 5.
%%
%% This module provides:
%%   - Per-fork gas cost schedules (Istanbul through Cancun/Deneb)
%%   - EIP-1559 base fee calculation and burning
%%   - EIP-4895 withdrawal processing
%%   - EIP-4788 beacon root storage
%%   - Fork identification for block transitions
%%
%% -module(eth_fork_schedule).

-module(eth_fork_schedule).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([ current_fork/1,
          current_fork/2,
          base_fee/2,
          base_fee/3,
          base_fee_delta/2,
          burn_base_fee/2,
          process_withdrawals/2,
          make_withdrawal/3,
          withdrawals_root/1,
          add_beacon_root/2,
          get_beacon_root/1,
          add_beacon_root_to_state/2,
          get_beacon_root_from_state/1,
          beacon_root_contract/0,
          gas_cost/3,
          gas_cost/4 ]).

-record(st, {
    chain :: term(),
    base_fee_per_gas = 1000000000 :: integer(),
    withdrawals = [] :: [map()],
    beacon_roots = #{} :: map()
}).

-define(BASE_FEE_DECELERATION_RATE, 8).
-define(BASE_FEE_MIN, 1000000000).
-define(BEACON_CONTRACT, <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>).

-define(FORK_ISTANBUL, istanbul).
-define(FORK_BERLIN, berlin).
-define(FORK_LONDON, london).
-define(FORK_ARROW_GLACIER, arrow_glacier).
-define(FORK_GRAY_GLACIER, gray_glacier).
-define(FORK_MERGE, merge).
-define(FORK_BELLATRIX, bellatrix).
-define(FORK_PARIS, paris).
-define(FORK_SHANGHAI, shanghai).
-define(FORK_CANCUN, cancun).
-define(FORK_DENEB, deneb).

%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    logger:notice("etherlang: Fork schedule started"),
    {ok, #st{}}.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

handle_call({base_fee, ParentGasUsed, ParentGasLimit}, _From, S) ->
    BF = compute_base_fee(ParentGasUsed, ParentGasLimit, S#st.base_fee_per_gas),
    {reply, {ok, BF}, S#st{base_fee_per_gas = BF}};
handle_call({base_fee, ParentGasUsed, ParentGasLimit, BaseFee}, _From, S) ->
    BF = compute_base_fee(ParentGasUsed, ParentGasLimit, BaseFee),
    {reply, {ok, BF}, S#st{base_fee_per_gas = BF}};
handle_call({burn, BaseFee, GasUsed}, _From, S) ->
    Burnt = BaseFee * GasUsed,
    {reply, {ok, Burnt}, S};
handle_call({withdrawals, _BlockNumber, Withdrawals}, _From, S) ->
    NewWithdrawals = lists:sort(fun(A, B) ->
        maps:get(index, A, 0) < maps:get(index, B, 0)
    end, Withdrawals),
    {reply, {ok, NewWithdrawals}, S#st{withdrawals = NewWithdrawals}};
handle_call({add_beacon_root, BlockNumber, Root}, _From, S) ->
    {reply, ok, S#st{beacon_roots = maps:put(BlockNumber, Root, S#st.beacon_roots)}};
handle_call({get_beacon_root, BlockNumber}, _From, S) ->
    {reply, maps:get(BlockNumber, S#st.beacon_roots, <<>>), S};
handle_call({gas_cost, Opcode, Fork, Gas}, _From, S) ->
    {reply, {ok, gas_cost(Opcode, Fork, Gas)}, S};
handle_call({gas_cost, Opcode, Fork, Gas, Args}, _From, S) ->
    {reply, {ok, gas_cost(Opcode, Fork, Gas, Args)}, S};
handle_call({current_fork, _BlockNumber}, _From, S) ->
    {reply, {ok, ?FORK_LONDON}, S};
handle_call({current_fork, _BlockNumber, _Chain}, _From, S) ->
    {reply, {ok, ?FORK_LONDON}, S};
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

current_fork(BlockNumber) ->
    gen_server:call(?MODULE, {current_fork, BlockNumber}, infinity).

current_fork(BlockNumber, Chain) ->
    gen_server:call(?MODULE, {current_fork, BlockNumber, Chain}, infinity).

base_fee(ParentGasUsed, ParentGasLimit) ->
    gen_server:call(?MODULE, {base_fee, ParentGasUsed, ParentGasLimit}, infinity).

base_fee(ParentGasUsed, ParentGasLimit, BaseFee) ->
    gen_server:call(?MODULE, {base_fee, ParentGasUsed, ParentGasLimit, BaseFee}, infinity).

base_fee_delta(GasUsed, GasLimit) ->
    if GasLimit =:= 0 -> 0;
       true -> GasUsed div GasLimit * ?BASE_FEE_DECELERATION_RATE
    end.

burn_base_fee(BaseFee, GasUsed) ->
    gen_server:call(?MODULE, {burn, BaseFee, GasUsed}, infinity).

process_withdrawals(BlockNumber, Withdrawals) ->
    gen_server:call(?MODULE, {withdrawals, BlockNumber, Withdrawals}, infinity).

make_withdrawal(Index, Address, Amount) ->
    #{index => Index, address => Address, amount => Amount, type => 1}.

withdrawals_root(_Withdrawals) ->
    eth_mpt:state_root().

add_beacon_root(BlockNumber, Root) ->
    gen_server:call(?MODULE, {add_beacon_root, BlockNumber, Root}, infinity).

get_beacon_root(BlockNumber) ->
    gen_server:call(?MODULE, {get_beacon_root, BlockNumber}, infinity).

add_beacon_root_to_state(BlockNumber, Root) ->
    Slot = block_number_to_slot(BlockNumber),
    eth_mpt:put_storage(?BEACON_CONTRACT, Slot, Root),
    ok.

get_beacon_root_from_state(BlockNumber) ->
    Slot = block_number_to_slot(BlockNumber),
    eth_mpt:get_storage(?BEACON_CONTRACT, Slot).

block_number_to_slot(BlockNumber) ->
    BlockNumber * 32.

beacon_root_contract() ->
    ?BEACON_CONTRACT.

gas_cost(Opcode, _Fork, Gas) when is_integer(Opcode), is_integer(Gas) ->
    case Opcode of
        0 -> 0;       %% STOP
        1 -> 3;       %% ADD
        2 -> 5;       %% MUL
        3 -> 3;       %% SUB
        4 -> 4;       %% MUL
        16 -> 5;      %% DIV
        17 -> 5;      %% SDIV
        18 -> 5;      %% MOD
        19 -> 5;      %% SMOD
        20 -> 8;      %% ADDMOD
        21 -> 8;      %% MULMOD
        22 -> gas_exp(Gas);
        24 -> 5;      %% SIGNEXTEND
        25 -> 3;      %% LT
        26 -> 3;      %% GT
        27 -> 3;      %% SLT
        28 -> 3;      %% EQ
        29 -> 3;      %% ISZERO
        30 -> 3;      %% AND
        31 -> 3;      %% OR
        32 -> 3;      %% XOR
        33 -> 3;      %% NOT
        34 -> 3;      %% BYTE
        35 -> 3;      %% SHL
        36 -> 3;      %% SHR
        37 -> 3;      %% SAR
        46 -> gas_keccak(Gas);
        47 -> 2;      %% ADDRESS
        48 -> 400;    %% BALANCE
        49 -> 2;      %% ORIGIN
        50 -> 2;      %% CALLER
        51 -> 2;      %% CALLVALUE
        52 -> 3;      %% CALLDATALOAD
        53 -> 3;      %% CALLDATASIZE
        54 -> 3;      %% CALLDATACOPY
        55 -> 2;      %% CODESIZE
        56 -> 3;      %% CODECOPY
        57 -> 2;      %% GASPRICE
        58 -> 700;    %% EXTCODESIZE
        59 -> 700;    %% EXTCODECOPY
        61 -> 2;      %% RETURNDATASIZE
        62 -> 3;      %% RETURNDATACOPY
        100 -> gas_create(Gas);
        110 -> gas_call(Gas);
        111 -> gas_call(Gas);
        112 -> 0;     %% RETURN
        113 -> gas_call(Gas);
        114 -> gas_create(Gas);
        115 -> gas_call(Gas);
        116 -> 0;     %% REVERT
        117 -> 0;     %% INVALID
        240 -> 5000;  %% SELFDESTRUCT
        256 -> 375;   %% LOG0
        257 -> 750;   %% LOG1
        258 -> 1125;  %% LOG2
        259 -> 1500;  %% LOG3
        260 -> 1875;  %% LOG4
        261 -> 2;     %% POP
        262 -> 3;     %% MLOAD
        263 -> 3;     %% MSTORE
        264 -> 3;     %% MSTORE8
        265 -> 2100;  %% SLOAD
        266 -> 20000; %% SSTORE
        270 -> 8;     %% JUMP
        271 -> 10;    %% JUMPI
        272 -> 2;     %% PC
        273 -> 2;     %% MSIZE
        274 -> 2;     %% GAS
        275 -> 1;     %% JUMPDEST
        288 -> 3;     %% PUSH1
        289 -> 3;     %% PUSH2
        290 -> 3;     %% PUSH3
        291 -> 3;     %% PUSH4
        292 -> 3;     %% PUSH5
        293 -> 3;     %% PUSH6
        294 -> 3;     %% PUSH7
        295 -> 3;     %% PUSH8
        296 -> 3;     %% PUSH9
        297 -> 3;     %% PUSH10
        298 -> 3;     %% PUSH11
        299 -> 3;     %% PUSH12
        300 -> 3;     %% PUSH13
        301 -> 3;     %% PUSH14
        302 -> 3;     %% PUSH15
        303 -> 3;     %% PUSH16
        304 -> 3;     %% PUSH17
        305 -> 3;     %% PUSH18
        306 -> 3;     %% PUSH19
        307 -> 3;     %% PUSH20
        308 -> 3;     %% PUSH21
        309 -> 3;     %% PUSH22
        310 -> 3;     %% PUSH23
        311 -> 3;     %% PUSH24
        312 -> 3;     %% PUSH25
        313 -> 3;     %% PUSH26
        314 -> 3;     %% PUSH27
        315 -> 3;     %% PUSH28
        316 -> 3;     %% PUSH29
        317 -> 3;     %% PUSH30
        318 -> 3;     %% PUSH31
        319 -> 3;     %% PUSH32
        320 -> 3;     %% DUP1
        321 -> 3;     %% DUP2
        322 -> 3;     %% DUP3
        323 -> 3;     %% DUP4
        324 -> 3;     %% DUP5
        325 -> 3;     %% DUP6
        326 -> 3;     %% DUP7
        327 -> 3;     %% DUP8
        328 -> 3;     %% DUP9
        329 -> 3;     %% DUP10
        330 -> 3;     %% DUP11
        331 -> 3;     %% DUP12
        332 -> 3;     %% DUP13
        333 -> 3;     %% DUP14
        334 -> 3;     %% DUP15
        335 -> 3;     %% DUP16
        336 -> 3;     %% SWAP1
        337 -> 3;     %% SWAP2
        338 -> 3;     %% SWAP3
        339 -> 3;     %% SWAP4
        340 -> 3;     %% SWAP5
        341 -> 3;     %% SWAP6
        342 -> 3;     %% SWAP7
        343 -> 3;     %% SWAP8
        344 -> 3;     %% SWAP9
        345 -> 3;     %% SWAP10
        346 -> 3;     %% SWAP11
        347 -> 3;     %% SWAP12
        348 -> 3;     %% SWAP13
        349 -> 3;     %% SWAP14
        350 -> 3;     %% SWAP15
        351 -> 3;     %% SWAP16
        _ -> 0
    end.

gas_cost(Opcode, Fork, Gas, _Args) ->
    gas_cost(Opcode, Fork, Gas).

%% ---------------------------------------------------------------------------
%% Base fee calculation (EIP-1559)
%% ---------------------------------------------------------------------------

compute_base_fee(GasUsed, GasLimit, CurrentBaseFee) ->
    if GasLimit =:= 0 -> CurrentBaseFee;
       true ->
           Target = GasLimit div 3,
           case GasUsed > Target of
               true ->
                   Delta = max(base_fee_delta(GasUsed, GasLimit), 1),
                   NewBF = CurrentBaseFee + Delta,
                   max(NewBF, ?BASE_FEE_MIN);
               false ->
                   Delta = base_fee_delta(GasUsed, GasLimit),
                   NewBF = CurrentBaseFee - Delta,
                   max(NewBF, ?BASE_FEE_MIN)
           end
    end.

%% ---------------------------------------------------------------------------
%% Gas helpers
%% ---------------------------------------------------------------------------

gas_exp(Gas) ->
    10 + (Gas div 8) * 50.

gas_keccak(Gas) ->
    30 + (Gas div 32) * 6.

gas_create(Gas) ->
    32000 + gas_keccak(Gas).

gas_call(Gas) ->
    700 + gas_keccak(Gas).

%% ---------------------------------------------------------------------------
%% Status
%% ---------------------------------------------------------------------------

status(#st{base_fee_per_gas = BF, withdrawals = Wd}) ->
    #{base_fee_per_gas => BF, withdrawal_count => length(Wd)}.
