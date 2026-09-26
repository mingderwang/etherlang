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
-export([new_payload/1, forkchoice_updated/1, get_payload/1,
         exchange_transition_config/1, jwt_secret/0]).

%% Engine API constants
-define(ENGINE_PORT, 8551).
-define(VALID, <<"VALID">>).
-define(INVALID, <<"INVALID">>).
-define(SYNCING, <<"SYNCING">>).
-define(ACCEPTED, <<"ACCEPTED">>).
-define(VALIDATED, <<"VALIDATED">>).
-define(INVALID_BLOCK_HASH, <<"INVALID_BLOCK_HASH">>).
-define(SECURITY_ERROR, <<"SECURITY_ERROR">>).

%% Engine state
%% Every field carries a default, which none of them did.
%%
%% init/1 names only some of them, and a field with no default is `undefined' in
%% every record the module builds. `payloads' is the one that mattered: init/1
%% never sets it, so it was `undefined', and the `maps:put/3' in new_payload/1
%% raised badmap on *every* payload. The catch around it turned that into
%% `{INVALID, {error, {badmap, undefined}}}', so engine_newPayloadV1 refused
%% well-formed payloads and malformed ones alike, and getPayload then had nothing
%% to return. A crash swallowed into a refusal is a failure with no symptom, which
%% is why nothing else flagged it.
%%
%% `head' was additionally typed `{integer(), binary()}' while being stored as
%% `{HeadHash, undefined}' and read out of the *second* position, so the value it
%% compared a payload's parentHash against was always `undefined' -- which
%% validate_payload/2 reads as "no opinion". The parent-hash check therefore never
%% rejected anything, whatever the head was. It is a plain binary now.
-record(st, {
    chain = eth_chain :: term(),
    sync = eth_sync :: term(),
    txpool = eth_txpool :: term(),
    evm = eth_evm :: term(),
    head = undefined :: binary() | undefined,
    %% The safe block and the finalized checkpoint, as the block hashes the client
    %% declared. These were `integer()' and were produced by asking eth_chain for
    %% the *number* of a hash, which is wrong twice over: the specification's
    %% fields are block hashes, and a number cannot tell two blocks at the same
    %% height apart. It also made forkchoiceUpdated depend on a chain process that
    %% need not be running -- and a call to it raised noproc, which the
    %% surrounding catch turned into `{error, {noproc, ...}}', so an entirely
    %% ordinary forkchoice update was answered with an error whenever eth_chain
    %% was not running.
    finalized = undefined :: binary() | undefined,
    safe = undefined :: binary() | undefined,
    terminal_total_difficulty = undefined :: integer() | undefined,
    terminal_block_hash = undefined :: binary() | undefined,
    terminal_block_number = 0 :: integer() | undefined,
    transition_configuration = undefined :: map() | undefined,
    jwt_secret = <<>> :: binary(),
    port = ?ENGINE_PORT :: integer(),
    started_at = 0 :: integer()
}).


%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link(Opts) ->
    start_link(eth_engine, Opts).

start_link(Name, Opts) when is_atom(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

%% The Engine API is a network port, so the specification requires it to be
%% authenticated (execution-apis, src/engine/authentication.md). A node with no
%% secret therefore has nothing to authenticate with, and the handler refuses the
%% port outright rather than serving it open -- an empty secret is not a request to
%% run without authentication.
jwt_secret(Opts) ->
    %% maps:get/3 with a <<>> default made "explicitly no secret" and "not
    %% configured" the same value, so a caller that passed <<>> to run without
    %% authentication silently got a generated one -- the opposite of what it
    %% asked for. The key's presence is what distinguishes them.
    case maps:find(jwt_secret, Opts) of
        {ok, Secret} ->
            Secret;
        error ->
            Dir = maps:get(data_dir, Opts, eth_config:data_dir()),
            case eth_jwt:load_or_create_secret(Dir) of
                {ok, Secret} ->
                    Secret;
                {error, Reason} ->
                    logger:error("etherlang: no engine API JWT secret (~p); "
                                 "the authenticated engine port will not be served",
                                 [Reason]),
                    <<>>
            end
    end.

init({_Name, Opts}) ->
    Port = maps:get(port, Opts, ?ENGINE_PORT),
    JWTSecret = jwt_secret(Opts),
    Chain = maps:get(chain, Opts, eth_chain),
    Sync = maps:get(sync, Opts, eth_sync),
    TxPool = maps:get(txpool, Opts, eth_txpool),
    EVM = maps:get(evm, Opts, eth_evm),
    TerminalTD = maps:get(terminal_total_difficulty, Opts, undefined),
    TerminalBlockHash = maps:get(terminal_block_hash, Opts, undefined),

    %% The port belongs to the listener in eth_rpc_server, not to this process,
    %% so this does not claim to be listening.
    logger:notice("etherlang: engine API state ready (JWT=~s)",
                  [case JWTSecret of
                       <<>> -> "UNAVAILABLE, the authenticated port will not be served";
                       _ -> "set"
                   end]),

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
%% This used to be `handle_call({save_state, _NewState}, _From, S) -> {reply, ok, S}',
%% which threw the state away and returned the old one. Every write the module
%% attempted was silently lost, so `forkchoice_updated/1' computed a new head, safe
%% block and finalized checkpoint, handed them to this clause, and they went
%% nowhere -- and the call still answered VALID. The underscore was the tell: a
%% parameter named for the thing being written and not used in the body.
handle_call({save_state, NewState}, _From, _S) -> {reply, ok, NewState};
handle_call(get_jwt_secret, _From, S) -> {reply, S#st.jwt_secret, S};
handle_call(_Req, _From, S) -> {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, #st{}) -> ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Engine API — Public Functions
%% ---------------------------------------------------------------------------

%% ---------------------------------------------------------------------------
%% Statuses
%% ---------------------------------------------------------------------------
%%
%% The status strings and which method may return which of them are taken from
%% the engine API specification (execution-apis, src/engine/paris.md):
%%
%%   PayloadStatusV1.status  = VALID | INVALID | SYNCING | ACCEPTED |
%%                             INVALID_BLOCK_HASH
%%   newPayloadV1            result is a PayloadStatusV1, with no payloadId
%%   forkchoiceUpdatedV1     result is {payloadStatus, payloadId}, and
%%                            payloadStatus.status is restricted to
%%                            VALID | INVALID | SYNCING -- ACCEPTED is not
%%                            permitted here
%%
%% ACCEPTED is in the enum, so returning it looks correct, but the specification
%% makes it a claim with preconditions: every transaction non-empty, the payload's
%% blockHash equal to Keccak256(RLP(header)), the payload not extending the
%% canonical chain, not fully validated, and its ancestors known and well-formed.
%% This node checks none of those and executes nothing, so ACCEPTED is as
%% unsupported here as VALID is. Every function below therefore returns a status
%% that means "not checked", and says so.

%% engine_newPayloadV1(Payload) -> Status() | {Status(), Reason}
%%
%% A payload this node cannot execute. The specification's SYNCING is defined as
%% "requisite data for the payload's acceptance or validation is missing", which
%% describes this node exactly: it holds no block to execute against and has no
%% payload decoder, so the transactions, the block hash, the state root, the
%% transactions root and the receipts root are all unexamined. INVALID is reserved
%% for what can be decided from the payload's shape alone.
new_payload(Payload) when is_map(Payload) ->
    case get_pid() of
        undefined ->
            ?SYNCING;
        Pid ->
            try
                State = gen_server:call(Pid, get_state, infinity),
                case payload_shape(Payload) of
                    ok ->
                        note_parent(State, Payload),
                        ?SYNCING;
                    {error, ShapeReason} ->
                        {?INVALID, ShapeReason}
                end
            catch
                Class:Reason:Stack ->
                    logger:warning("etherlang: engine new_payload error ~p:~p~n~p",
                                   [Class, Reason, Stack]),
                    {?INVALID, {Reason}}
            end
    end;
new_payload(_Payload) ->
    {?INVALID, payload_not_an_object}.

%% The only thing decidable without a decoder. A payload with no parent hash
%% cannot be placed on any chain, so no status derived from execution could
%% describe it; the specification's INVALID cases are about the payload's
%% contents, and a missing parent hash is a malformed request.
%%
%% This deliberately does *not* compare the parent hash against the recorded
%% head. That used to be the whole of validate_payload/2, and it could only
%% produce INVALID -- but a payload whose parent is not the head is not invalid,
%% it is a side branch or a block this node has not imported, and the
%% specification answers SYNCING to both. So the check could not decide anything
%% and is not repeated here. The comparison is made in note_parent/2 for the log
%% only.
payload_shape(Payload) ->
    case field(Payload, "parentHash", undefined) of
        undefined ->
            {error, missing_parent_hash};
        Hash ->
            case data32(Hash) of
                {ok, _Bytes} -> ok;
                {error, Why} -> {error, {malformed_parent_hash, Why}}
            end
    end.

%% The recorded head is consulted for the log line only. Until a payload decoder
%% exists there is nothing to compare a parent hash against that could change a
%% status, so this is the single place the field is read.
note_parent(State, Payload) ->
    Parent = case data32(field(Payload, "parentHash", undefined)) of
        {ok, Bytes} -> Bytes;
        {error, _} -> undefined
    end,
    case {State#st.head, Parent} of
        {undefined, _} ->
            ok;
        {_Head, undefined} ->
            ok;
        {Head, Parent} when Head =:= Parent ->
            ok;
        {Head, Parent} ->
            logger:info("etherlang: engine payload parent ~s is not the recorded head ~s",
                        [fmt(Parent), fmt(Head)])
    end.

%% engine_forkchoiceUpdatedV1(Params) -> Status() | {error, Reason}
%%
%% The specification restricts this method's status to VALID, INVALID and
%% SYNCING. It returns VALID when the payload the client names is VALID -- that
%% is, when payload validation has run and passed -- and SYNCING when the head
%% "references an unknown payload or a payload that can't be validated because
%% requisite data for the validation is missing".
%%
%% This node runs no payload validation, so a head it has not itself validated
%% is not VALID, however confident the client is about it. It previously returned
%% VALID unconditionally, which is the one status a node that has looked at
%% nothing cannot justify, and this method is how a consensus client decides
%% whether to trust this node's view of the chain.
%%
%% VALID is still returned for the case where there is nothing to judge: no head
%% claimed and no payload to build on.
forkchoice_updated(ForkChoiceState) when is_map(ForkChoiceState) ->
    apply_forkchoice(ForkChoiceState);
forkchoice_updated(_ForkChoiceState) ->
    {error, invalid_forkchoice_state}.

%% The argument is the forkchoiceState itself. This took the whole JSON-RPC
%% `params' envelope and dug out a "forkChoice" key from it, which the
%% specification does not have: the state arrives as params[0]. The envelope and
%% the state are different things, and reading one as the other is why every
%% forkchoice update over HTTP was answered `invalid params'.
%%
%% field/3 is still what reads the three hashes and the payloadId, so both key
%% forms are accepted inside it.
%% A head that is present but is not 32 bytes of DATA cannot name a block, so
%% the state is inconsistent. The specification's answer for that is -38002
%% "Invalid forkchoice state", and it is a real check: the alternative is to
%% record a head this node can never match a payload against.
apply_forkchoice(ForkChoice) ->
    case check_head(ForkChoice) of
        ok ->
            do_apply_forkchoice(ForkChoice);
        {error, Reason} ->
            {error, Reason}
    end.

check_head(ForkChoice) ->
    case field(ForkChoice, "headBlockHash", undefined) of
        undefined ->
            ok;
        Hash ->
            case malformed(Hash) of
                false -> ok;
                true -> {error, invalid_forkchoice_state}
            end
    end.

%% True when the value is a non-empty hash that is not 32 bytes of DATA.
malformed(Hash) when is_binary(Hash) ->
    case Hash of
        <<"0x", _/binary>> ->
            case data32(Hash) of
                {error, _} -> true;
                _ -> false
            end;
        _ when byte_size(Hash) =:= 32 -> false;
        _ -> true
    end;
malformed(_Hash) ->
    true.

do_apply_forkchoice(ForkChoice) ->
    case get_pid() of
        undefined -> ?SYNCING;
        Pid ->
            try
                HeadHash = field(ForkChoice, "headBlockHash", undefined),
                SafeHash = field(ForkChoice, "safeBlockHash", undefined),
                FinalizedHash = field(ForkChoice, "finalizedBlockHash", undefined),
                PayloadId = field(ForkChoice, "payloadId", undefined),
                State = gen_server:call(Pid, get_state, infinity),
                NewState = State#st{
                    %% What the client declares, recorded. This is the client's
                    %% view of the chain, not a block this node has validated, and
                    %% the status below is what the client is told about it.
                    head = hash_or(HeadHash, State#st.head),
                    %% hash_or/2 maps an absent or all-zero hash to the previous
                    %% value, which is how the specification's "not said yet"
                    %% marker is expressed.
                    safe = hash_or(SafeHash, State#st.safe),
                    finalized = hash_or(FinalizedHash, State#st.finalized),
                    terminal_total_difficulty = terminal_total_difficulty(State)
                },
                _ = gen_server:call(Pid, {save_state, NewState}, infinity),
                forkchoice_status(hash_or(HeadHash, undefined), PayloadId)
            catch
                Class:Reason:Stack ->
                    logger:warning("etherlang: engine forkchoice error ~p:~p~n~p",
                                   [Class, Reason, Stack]),
                    {error, Reason}
            end
    end.

%% The head is normalised first, so an absent or all-zero hash -- which the
%% specification allows for safe and finalized, and which means "not claimed" --
%% is indistinguishable from the client saying nothing.
forkchoice_status(undefined, undefined) ->
    ?VALID;
forkchoice_status(_Head, _PayloadId) ->
    %% Either a head this node has not validated, or a payloadId from a build
    %% process this node never started. Both are the specification's SYNCING.
    ?SYNCING.

%% engine_getPayloadV1(PayloadId) -> {payload, Payload} | {error, Reason}
%%
%% The specification takes an 8-byte payloadId and returns the ExecutionPayloadV1
%% built by the build process that issued it. This function used to take no
%% argument and returned the last payload the client had itself submitted through
%% newPayload -- not a block this node built, and not even necessarily a block
%% this node agrees is valid. Handing that to a consensus client invites it to
%% broadcast a block the execution layer never produced, so the signature now
%% matches the specification and the honest answer is reported instead.
%%
%% The builder that would issue payloadIds is `eth_block_builder', which is not
%% started (see the Phase 3 notes in TASKS.md), so no payloadId this node could be
%% asked about is one it issued.
get_payload(PayloadId) ->
    case data(PayloadId, 8) of
        {ok, _Bytes} -> {error, unknown_payload};
        {error, _Why} -> {error, invalid_params}
    end.

%% engine_exchangeTransitionConfigurationV1(Config) -> {ok, Config} | {error, Reason}
%%
%% The specification's result here is a TransitionConfigurationV1 -- an object
%% with terminalTotalDifficulty, terminalBlockHash and terminalBlockNumber -- not
%% a status. This returned a bare VALID, so the client received no configuration
%% at all from the one method whose entire purpose is to hand it over.
exchange_transition_config(Config) when is_map(Config) ->
    case get_pid() of
        undefined -> {error, not_running};
        Pid ->
            try
                State = gen_server:call(Pid, get_state, infinity),
                TTD = quantity(field(Config, "terminalTotalDifficulty", undefined),
                               terminal_total_difficulty(State)),
                TBH = hash_or(field(Config, "terminalBlockHash", undefined), undefined),
                TBN = quantity(field(Config, "terminalBlockNumber", undefined), 0),
                NewState = State#st{
                    terminal_total_difficulty = TTD,
                    terminal_block_hash = TBH,
                    terminal_block_number = TBN,
                    transition_configuration = #{
                        terminal_total_difficulty => TTD,
                        terminal_block_hash => TBH,
                        terminal_block_number => TBN
                    }
                },
                _ = gen_server:call(Pid, {save_state, NewState}, infinity),
                {ok, #{
                    terminal_total_difficulty => TTD,
                    terminal_block_hash => TBH,
                    terminal_block_number => TBN
                }}
            catch
                Class:Reason:Stack ->
                    logger:warning("etherlang: engine exchange config error ~p:~p~n~p",
                                   [Class, Reason, Stack]),
                    {error, Reason}
            end
    end;
exchange_transition_config(_Config) ->
    {error, invalid_params}.

%% The terminal total difficulty was decoded with binary_to_integer/1, which is
%% base 10, so every real value -- "0xc70d815d562d3cfa955" for mainnet, and the
%% 2^256-1 sentinel the specification mandates for an undecided value -- raised
%% badarg and the catch turned it into SECURITY_ERROR. The transition
%% configuration could therefore never be exchanged for any network. It is a hex
%% quantity by specification, so it is decoded as one.
%%
%% The configuration map was also built from the *previous* state's values rather
%% than the ones just parsed, so what the node recorded was always one exchange
%% out of date -- and the specification has the client receive these values back
%% from this call, so the staleness was visible to the consensus client.
%%

%% The specification: in the absence of a TERMINAL_TOTAL_DIFFICULTY value both
%% layers must use 2^256-1. Quoted from src/engine/paris.md clause 7:
%% "Considering the absence of the `TERMINAL_TOTAL_DIFFICULTY` value ... Client
%% software **MUST** use
%% 1157920892373161954235709850086879078532699846656405640394575840079131296"
-define(NO_TERMINAL_TOTAL_DIFFICULTY,
        16#ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff).

terminal_total_difficulty(State) ->
    case State#st.terminal_total_difficulty of
        undefined -> ?NO_TERMINAL_TOTAL_DIFFICULTY;
        TD -> TD
    end.

fmt(undefined) -> "none";
fmt(Hash) when is_binary(Hash), byte_size(Hash) =:= 32 ->
    iolist_to_binary(["0x", binary:encode_hex(Hash)]);
fmt(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% ---------------------------------------------------------------------------
%% Field access
%% ---------------------------------------------------------------------------
%%
%% Every lookup in this module was `maps:get("someKey", Map, Default)' with a
%% *string* key. The engine API is JSON, and a decoded JSON object has binary
%% keys, so over HTTP none of these lookups ever found anything: newPayload saw no
%% parentHash and answered INVALID with missing_parent_hash, forkchoice saw no
%% head and answered VALID, and the transition configuration kept the values it
%% already had. All three methods returned well-formed statuses while reading
%% nothing at all. Tests calling this module with string keys would not have shown
%% it, which is part of why there were none.
%%
%% Both forms are accepted, binary first, since that is what a real request
%% carries.
field(Map, Key, Default) when is_map(Map), is_list(Key) ->
    case maps:find(list_to_binary(Key), Map) of
        {ok, Value} -> Value;
        error -> maps:get(Key, Map, Default)
    end;
field(_Map, _Key, Default) ->
    Default.

%% A JSON quantity: a hex string, a list, or already an integer. Anything
%% unparseable keeps the previous value rather than guessing at one, because a
%% misread total difficulty would move a fork boundary.
quantity(undefined, Default) ->
    Default;
quantity(Value, _Default) when is_integer(Value) ->
    Value;
quantity(Value, Default) ->
    try eth_hex:decode(Value)
    catch _:_ -> Default
    end.

%% ---------------------------------------------------------------------------
%% Forkchoice status
%% ---------------------------------------------------------------------------

%% An all-zero hash is the specification's "not claimed" marker for the safe and
%% finalized fields, and the engine API sends it as a placeholder in other
%% places. It is normalised to undefined here so it cannot be mistaken for a head
%% the node has a record of.
hash_or(Hash, _Default) when is_binary(Hash) ->
    case data32(Hash) of
        {ok, Bytes} when Bytes =:= <<0:256>> -> _Default;  % the "not claimed" marker
        {ok, Bytes} -> Bytes;
        {error, _} -> _Default
    end;
hash_or(_Hash, Default) ->
    Default.

%% A JSON DATA value is a 0x-prefixed string of exactly 64 hex nibbles, and a
%% decoded JSON object carries it as a *string* -- `<<"0xab...", 66 bytes>>'` --
%% not as the 32 raw bytes it denotes. Requiring 32 raw bytes would have refused
%% every real payload while accepting only what an Erlang caller happens to hold,
%% which is how a check can be present, look right, and never fire. Raw bytes are
%% accepted as well, since that is what an in-process caller naturally has.
data32(Value) -> data(Value, 32).

%% A JSON DATA value is a 0x-prefixed string of exactly 2*N hex nibbles, and a
%% decoded JSON object carries it as a *string* -- `<<"0xab...", 66 bytes>>'` --
%% not as the 32 raw bytes it denotes. Requiring 32 raw bytes would have refused
%% every real payload while accepting only what an Erlang caller happens to hold,
%% which is how a check can be present, look right, and never fire. Raw bytes are
%% accepted as well, since that is what an in-process caller naturally has and
%% what the record stores: a validator that rejects the form it stores is not a
%% validator.
data(Value, N) when is_binary(Value) ->
    case Value of
        <<"0x", Hex/binary>> -> hex_to_bytes(Hex, N);
        <<"0X", Hex/binary>> -> hex_to_bytes(Hex, N);
        _ when byte_size(Value) =:= N -> {ok, Value};
        _ -> hex_to_bytes(Value, N)
    end;
data(_Value, _N) ->
    {error, not_data}.

hex_to_bytes(Hex, N) ->
    case byte_size(Hex) =:= 2 * N andalso eth_hex:is_hex(Hex) of
        true ->
            try {ok, binary:decode_hex(Hex)}
            catch _:_ -> {error, not_hex}
            end;
        false ->
            {error, {wrong_length, N}}
    end.

%% ---------------------------------------------------------------------------
%% Internal Helpers
%% ---------------------------------------------------------------------------

%% The handler authenticates each request against this. An empty secret means the
%% node could not obtain one, which the handler treats as "do not serve the port".
jwt_secret() ->
    case get_pid() of
        undefined -> {error, not_running};
        Pid ->
            case gen_server:call(Pid, get_jwt_secret, infinity) of
                <<>> -> {error, no_secret};
                Secret -> {ok, Secret}
            end
    end.

get_pid() ->
    case whereis(eth_engine) of
        undefined -> undefined;
        Pid -> Pid
    end.
