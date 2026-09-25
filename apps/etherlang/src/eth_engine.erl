%% Engine API server (EIP-3675 / Cancun).
%%
%% This module implements the execution engine interface that allows
%% consensus clients (Lighthouse, Prysm, Nimbus, Teku, Lodestar) to
%% delegate block execution to etherlang.
%%
%% Methods implemented:
%%   - engine_newPayloadV1
%%   - engine_forkchoiceUpdatedV1
%%   - engine_getPayloadV1
%%   - engine_exchangeTransitionConfigurationV1
%%
%% Status codes returned:
%%   - "VALID": payload is valid and can be executed
%%   - "INVALID": payload is invalid
%%   - "SYNCING": node is syncing, cannot accept payloads yet
%%   - "ACCEPTED": payload is valid and accepted for execution
%%   - "VALIDATED": payload has been validated and executed
%%   - "INVALID_BLOCK_HASH": terminal block hash mismatch
%%   - "SECURITY_ERROR": security validation failure
%%
%% -module(eth_engine).

-module(eth_engine).

-behaviour(gen_server).

-export([start_link/1, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([new_payload/1, forkchoice_updated/1, get_payload/0, exchange_transition_config/1]).

%% Engine state
-record(st, {
    chain :: term(),
    sync :: term(),
    txpool :: term(),
    evm :: term(),
    head :: {integer(), binary()} | undefined,
    finalized :: integer() | undefined,
    safe :: integer() | undefined,
    terminal_total_difficulty :: integer() | undefined,
    terminal_block_hash :: binary() | undefined,
    transition_configuration :: map() | undefined,
    payloads :: map(),
    latest_payload_id :: binary() | undefined,
    jwt_secret :: binary(),
    port :: integer(),
    started_at :: integer()
}).

%% Engine API constants
-define(ENGINE_PORT, 8551).
-define(VALID, <<"VALID">>).
-define(INVALID, <<"INVALID">>).
-define(SYNCING, <<"SYNCING">>).
-define(ACCEPTED, <<"ACCEPTED">>).
-define(VALIDATED, <<"VALIDATED">>).
-define(INVALID_BLOCK_HASH, <<"INVALID_BLOCK_HASH">>).
-define(SECURITY_ERROR, <<"SECURITY_ERROR">>).

%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link(Opts) ->
    start_link(eth_engine, Opts).

start_link(Name, Opts) when is_atom(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

init({_Name, Opts}) ->
    Port = maps:get(port, Opts, ?ENGINE_PORT),
    JWTSecret = maps:get(jwt_secret, Opts, <<>>),
    Chain = maps:get(chain, Opts, eth_chain),
    Sync = maps:get(sync, Opts, eth_sync),
    TxPool = maps:get(txpool, Opts, eth_txpool),
    EVM = maps:get(evm, Opts, eth_evm),
    TerminalTD = maps:get(terminal_total_difficulty, Opts, undefined),
    TerminalBlockHash = maps:get(terminal_block_hash, Opts, undefined),

    logger:notice("etherlang: Engine API listening on port ~p (JWT=~s)",
                  [Port, case JWTSecret of "" -> "disabled"; _ -> "set" end]),

    State = #st{
        chain = Chain,
        sync = Sync,
        txpool = TxPool,
        evm = EVM,
        port = Port,
        jwt_secret = JWTSecret,
        terminal_total_difficulty = TerminalTD,
        terminal_block_hash = TerminalBlockHash,
        started_at = erlang:system_time(millisecond)
    },
    {ok, State}.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

handle_call(get_state, _From, S) -> {reply, S, S};
handle_call({save_state, _NewState}, _From, S) -> {reply, ok, S};
handle_call(get_jwt_secret, _From, S) -> {reply, S#st.jwt_secret, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #st{}) -> ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Engine API — Public Functions
%% ---------------------------------------------------------------------------

%% engine_newPayloadV1(Payload) -> {Status(), PayloadId} | {error, Reason}
%% Receive and validate an execution payload from the consensus client.
new_payload(Payload) when is_map(Payload) ->
    case get_pid() of
        undefined -> {?SYNCING, undefined};
        Pid ->
            try
                State = gen_server:call(Pid, get_state, infinity),
                case validate_payload(Payload, State) of
                    ok ->
                        PayloadId = generate_payload_id(),
                        PayloadState = State#st{
                            payloads = maps:put(PayloadId, Payload, State#st.payloads),
                            latest_payload_id = PayloadId
                        },
                        ok = PayloadState,
                        {?ACCEPTED, PayloadId};
                    {error, _VReason} ->
                        {?INVALID, _VReason}
                end
            catch
                Class:Reason:Stack ->
                    logger:warning("etherlang: engine new_payload error ~p:~p~n~p",
                                   [Class, Reason, Stack]),
                    {?INVALID, {error, Reason}}
            end
    end.

%% engine_forkchoiceUpdatedV1(ForkChoice) -> status()
%% Handle safe/finalized forkchoice updates from the consensus client.
forkchoice_updated(#{<<"forkChoice">> := ForkChoice}) when is_map(ForkChoice) ->
    case get_pid() of
        undefined -> {?SYNCING, undefined};
        Pid ->
            try
                HeadHash = maps:get("headBlockHash", ForkChoice, undefined),
                SafeHash = maps:get("safeBlockHash", ForkChoice, undefined),
                FinalizedHash = maps:get("finalizedBlockHash", ForkChoice, undefined),
                State = gen_server:call(Pid, get_state, infinity),
                NewState = State#st{
                    head = {HeadHash, undefined},
                    safe = case SafeHash of
                        undefined -> State#st.safe;
                        _ -> hash_to_num(SafeHash)
                    end,
                    finalized = case FinalizedHash of
                        undefined -> State#st.finalized;
                        _ -> hash_to_num(FinalizedHash)
                    end
                },
                _ = gen_server:call(Pid, {save_state, NewState}, infinity),
                ?VALID
            catch
                Class:Reason:Stack ->
                    logger:warning("etherlang: engine forkchoice error ~p:~p~n~p",
                                   [Class, Reason, Stack]),
                    {?SECURITY_ERROR, Reason}
            end
    end;
forkchoice_updated(_) ->
    {?INVALID, invalid_params}.

%% engine_getPayloadV1() -> {payload, Payload} | {error, Reason}
%% Return the latest payload for the consensus client to broadcast.
get_payload() ->
    try
        State = gen_server:call(get_pid(), get_state, infinity),
        case State#st.latest_payload_id of
            undefined -> {error, no_payload};
            PayloadId ->
                case maps:get(PayloadId, State#st.payloads, undefined) of
                    undefined -> {error, payload_not_found};
                    Payload -> {payload, Payload}
                end
        end
    catch
        Class:Reason:Stack ->
            logger:warning("etherlang: engine get_payload error ~p:~p~n~p",
                           [Class, Reason, Stack]),
            {error, Reason}
    end.

%% engine_exchangeTransitionConfigurationV1(Config) -> status()
%% Negotiate engine version and transition configuration.
exchange_transition_config(Config) when is_map(Config) ->
    case get_pid() of
        undefined -> {?SYNCING, undefined};
        Pid ->
            try
                TerminalTD = maps:get("terminalTotalDifficulty", Config, undefined),
                TerminalBlockHash = maps:get("terminalBlockHash", Config, undefined),
                MaxEntropyName = maps:get(
                    "maxEntropyForkchoiceUpdatedName", Config, undefined),
                State = gen_server:call(Pid, get_state, infinity),
                NewState = State#st{
                    terminal_total_difficulty = case TerminalTD of
                        undefined -> State#st.terminal_total_difficulty;
                        TD when is_integer(TD) -> TD;
                        TD when is_binary(TD) -> binary_to_integer(TD)
                    end,
                    terminal_block_hash = case TerminalBlockHash of
                        undefined -> State#st.terminal_block_hash;
                        HB when is_binary(HB) -> HB
                    end,
                    transition_configuration = #{
                        terminal_total_difficulty => State#st.terminal_total_difficulty,
                        terminal_block_hash => State#st.terminal_block_hash,
                        max_entropy_forkchoice_updated_name => MaxEntropyName
                    }
                },
                _ = gen_server:call(Pid, {save_state, NewState}, infinity),
                ?VALID
            catch
                Class:Reason:Stack ->
                    logger:warning("etherlang: engine exchange_transition_config error ~p:~p~n~p",
                                   [Class, Reason, Stack]),
                    {?SECURITY_ERROR, Reason}
            end
    end.

%% ---------------------------------------------------------------------------
%% Payload Validation
%% ---------------------------------------------------------------------------

validate_payload(Payload, #st{head = Head}) ->
    PayloadParent = maps:get("parentHash", Payload, undefined),
    HeadHash = case Head of
        {_, H} -> H;
        H when is_binary(H) -> H;
        undefined -> undefined
    end,
    case {PayloadParent, HeadHash} of
        {undefined, _} -> {error, missing_parent_hash};
        {_, undefined} -> ok;
        {PayloadParent, HeadHash} when PayloadParent =:= HeadHash -> ok;
        _ -> {error, parent_hash_mismatch}
    end.

%% ---------------------------------------------------------------------------
%% Internal Helpers
%% ---------------------------------------------------------------------------

get_pid() ->
    case whereis(eth_engine) of
        undefined -> undefined;
        Pid -> Pid
    end.

generate_payload_id() ->
    <<Int:64/little-unsigned-integer>> = crypto:strong_rand_bytes(8),
    eth_hex:encode(Int).

hash_to_num(Hash) ->
    case eth_chain:get_by_hash(Hash) of
        {ok, Num, _} -> Num;
        _ -> undefined
    end.
