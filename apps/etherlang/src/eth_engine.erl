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
-export([new_payload/1, forkchoice_updated/1, forkchoice_updated/2, get_payload/1,
         exchange_transition_config/1, jwt_secret/0,
         %% Exported so the status mapping can be tested against the finalize
         %% results eth_finalize_tests produces, rather than only through a path
         %% that needs the parent block's state held locally.
         status_for_finalize/1, status_for_verification/1,
         %% Exported, and pure, for the same reason: the version and fork gates
         %% decide *whether* a payload is processed at all, so a test that can
         %% only reach them over HTTP cannot distinguish "the gate refused it"
         %% from "the gate was never consulted".
         payload_admission/2, attributes_admission/2,
         build_attributes/2,
         blob_hashes_admission/2, status_for_version/2,
         version_fork/1, structure_for_version/2,
         required_structure/1, required_attributes/1,
         %% The module's one DATA reader, exported because the handler checks a DATA
         %% parameter of its own (newPayloadV3's parentBeaconBlockRoot) and writing
         %% a second decoder there was how that check came to reject every
         %% well-formed value: eth_hex:decode/1 returns an integer, so the second
         %% decoder could never produce the 32 bytes it was testing for.
         data32/1 ]).

%% Engine API constants
-define(ENGINE_PORT, 8551).
-define(VALID, <<"VALID">>).
-define(INVALID, <<"INVALID">>).
-define(SYNCING, <<"SYNCING">>).
-define(ACCEPTED, <<"ACCEPTED">>).
-define(VALIDATED, <<"VALIDATED">>).
-define(INVALID_BLOCK_HASH, <<"INVALID_BLOCK_HASH">>).
-define(SECURITY_ERROR, <<"SECURITY_ERROR">>).

%% JSON-RPC error codes the engine API specifies. The three -380xx codes are from
%% execution-apis src/engine/common.md, "Engine API error codes":
%%
%%   | -38001 | Unknown payload            |
%%   | -38002 | Invalid forkchoice state  |
%%   | -38003 | Invalid payload attributes|
%%   | -38004 | Too large request         |
%%   | -38005 | Unsupported fork          |
%%
%% -32602 is JSON-RPC's own "Invalid params", not an engine-specific code, and
%% is the code the versioned methods use for a structure mismatch.
-define(INVALID_PARAMS, -32602).
-define(UNSUPPORTED_FORK, -38005).
-define(INVALID_ATTRIBUTES, -38003).

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
%% Versioned-method admission
%% ---------------------------------------------------------------------------
%%
%% The engine API's methods are versioned, and the version is not decoration: a
%% V2 method on a V2 payload and a V2 method on a V1 payload are different calls
%% with different answers, and the specification gives the wrong pairing an error
%% code rather than a payload status. Before Cancun this node implemented only the
%% V1 methods, so a post-Merge consensus client -- which calls
%% engine_forkchoiceUpdatedV3 and engine_getPayloadV3, and has since Osaka
%% engine_forkchoiceUpdatedV4 -- was answered `-32601 method not found' for every
%% call. That is a node no consensus layer can drive, whatever else it can do.
%%
%% Two gates, in the order the specification lists them. From
%% execution-apis src/engine/cancun.md, engine_newPayloadV3:
%%
%%   1. "Client software MUST check that provided set of parameters and their
%%      fields strictly matches the expected one and return `-32602: Invalid
%%      params' error if this check fails. Any field having `null' value MUST be
%%      considered as not provided."
%%   2. "Client software MUST return `-38005: Unsupported fork' error if the
%%      `timestamp' of the payload does not fall within the time frame of the
%%      Cancun fork."
%%
%% Both are *errors* and not statuses, and that distinction is the whole point. A
%% PayloadStatusV1 is a verdict on a payload; -32602 and -38005 say the request
%% was malformed or aimed at the wrong fork, and the payload was never judged.
%% Reporting either as SYNCING would tell a client "I will get to this later" about
%% something this node has already decided it cannot accept, and the client would
%% keep offering it.
%%
%% The structure check is on the *keys*, not the values: a V1 payload is a V2
%% payload minus `withdrawals', a V2 is a V3 minus `blobGasUsed' and
%% `excessBlobGas', and each fork only ever appended. So which of the appended keys
%% are present identifies the structure, and `null' counts as absent per item 1.
%% The value-level check is eth_block:from_payload/1's job and runs after
%% admission, which is the order the specification gives: the parameter check
%% precedes the blockHash check, which precedes execution.
%%
%% "Strictly matches" is taken literally: the set of fork-specific keys a payload
%% carries must *equal* the set its version calls for, not merely contain it. The
%% weaker reading has a concrete failure -- ExecutionPayloadV3 is a superset of
%% V2, so a Prague payload would satisfy a V2 method's requirements and be
%% accepted by a node that cannot execute Prague rules. Rejecting the extra keys
%% is what makes "use the version that matches" enforceable rather than advisory.

%% The keys each fork appended, in the order the forks appended them. Paris is the
%% base set, which eth_block:from_payload/1 checks field by field; only the
%% appended keys are listed here because only they distinguish one version's
%% structure from another's.
required_structure(paris) -> [];
required_structure(shanghai) -> [<<"withdrawals">>];
required_structure(cancun) -> [<<"withdrawals">>, <<"blobGasUsed">>,
                              <<"excessBlobGas">>];
%% **EIP-7928's `blockAccessList` and EIP-7843's `slotNumber`,** which is what
%% `ExecutionPayloadV4` appends. `executionRequests` is deliberately **not** here: it is
%% `newPayloadV5`'s fourth *parameter*, not a payload field, and a structure check that
%% demanded it would refuse every payload sent to any other method.
required_structure(amsterdam) -> [<<"withdrawals">>, <<"blobGasUsed">>,
                                 <<"excessBlobGas">>, <<"blockAccessList">>,
                                 <<"slotNumber">>].

%% Every key any version appends, so "the keys this payload carries" is a
%% comparison over a fixed set rather than over the payload's own keys. A payload
%% with a key not in this list cannot be versioned by it, and
%% structure_admission/2 will not notice -- eth_block:from_payload/1 ignores
%% unknown fields too, which is a separate, documented looseness.
appended_keys() -> [<<"withdrawals">>, <<"blobGasUsed">>, <<"excessBlobGas">>,
                    <<"blockAccessList">>, <<"slotNumber">>].

%% payloadAttributes has its own version line, and it is *not* the payload's.
%% PayloadAttributesV1 is timestamp, prevRandao and suggestedFeeRecipient
%% (src/engine/paris.md); V2 appends withdrawals (src/engine/shanghai.md,
%% PayloadAttributesV2); V3 appends parentBeaconBlockRoot (src/engine/cancun.md,
%% PayloadAttributesV3: "This structure has the syntax of PayloadAttributesV2 and
%% appends a single field: parentBeaconBlockRoot").
%%
%% So V3 attributes carry parentBeaconBlockRoot and *not* blobGasUsed or
%% excessBlobGas, which are header fields of the payload and not attributes at all.
%% Reusing required_structure/1 for the attributes -- which is the obvious thing to
%% write, since both are versioned -- checks for the wrong keys twice over: a
%% correct V3 attributes object is refused for lacking blobGasUsed, and a payload's
%% key set is demanded of an object that has none of them.
required_attributes(paris) -> [];
required_attributes(shanghai) -> [<<"withdrawals">>];
required_attributes(cancun) -> [<<"withdrawals">>, <<"parentBeaconBlockRoot">>];
%% **`PayloadAttributesV4` "has the syntax of PayloadAttributesV3 and appends two new
%% fields: `slotNumber` and `targetGasLimit`"** (execution-apis src/engine/amsterdam.md).
%%
%% `targetGasLimit` appears in **neither** EIP-7843 nor EIP-7928 and is in neither header
%% field list this node encodes -- it is a *target*, and nothing in the header commits to it.
%% It is listed here because the attributes object must carry it to match the structure, and
%% **this node does not act on it**: a `gasLimit` other than the one the block's own header
%% carries would change the block, and there is no rule in the header or the fork schedule
%% that says which target wins. Recorded rather than silently accepted.
required_attributes(amsterdam) -> [<<"withdrawals">>, <<"parentBeaconBlockRoot">>,
                                   <<"slotNumber">>, <<"targetGasLimit">>];
%% Prague's method is `getPayloadV4` and its attributes object is still `PayloadAttributesV3`
%% (src/engine/prague.md adds `executionRequests` to the *response*, not to the attributes),
%% so V4 asks for exactly what V3 asked for.
required_attributes(prague) -> required_attributes(cancun).

appended_attribute_keys() -> [<<"withdrawals">>, <<"parentBeaconBlockRoot">>,
                              <<"slotNumber">>, <<"targetGasLimit">>].

%% The structure a method of the given version requires of a payload whose
%% timestamp is Timestamp.
%%
%% V1 has exactly one structure. V2 selects between two by timestamp, from
%% execution-apis src/engine/shanghai.md, engine_newPayloadV2:
%%
%%   "ExecutionPayloadV1 MUST be used if the `timestamp' value is lower than the
%%    Shanghai timestamp, ExecutionPayloadV2 MUST be used if the `timestamp' value
%%    is greater or equal to the Shanghai timestamp, Client software MUST return
%%    `-32602: Invalid params' error if the wrong version of the structure is used
%%    in the method call."
%%
%% V3 is Cancun only, so its structure is fixed and the timestamp is checked
%% against the Cancun frame instead.
%%
%% Note that V2's rule is a *one-sided* comparison ("lower than", "greater or
%% equal"), so this asks for the Shanghai activation instant and not for Shanghai's
%% frame. Shanghai's frame closes when Cancun opens, and using it here would make
%% every post-Cancun timestamp look pre-Shanghai and demand the V1 structure of a
%% Cancun payload.
-spec structure_for_version(integer(), integer()) -> atom().
structure_for_version(1, _Timestamp) -> paris;
structure_for_version(2, Timestamp) ->
    case at_or_after(shanghai, Timestamp) of
        true -> shanghai;
        false -> paris
    end;
structure_for_version(3, _Timestamp) -> cancun;
%% **`newPayloadV4` and `newPayloadV5` are two methods over three payload structures.**
%% `ExecutionPayloadV4` "has the syntax of ExecutionPayloadV3 and appends the new field:
%% blockAccessList" (execution-apis src/engine/amsterdam.md), so a Prague payload is still
%% V3-shaped and `newPayloadV4` -- which is Prague's method -- asks for `cancun'. Only V5
%% asks for the Amsterdam structure. Conflating the method number with the structure number
%% is the mistake this clause exists to prevent: the handler passes the *method* version.
structure_for_version(4, _Timestamp) -> cancun;
structure_for_version(5, _Timestamp) -> amsterdam.

%% One-sided: has this fork activated yet?
at_or_after(Fork, Timestamp) ->
    case eth_fork_schedule:activated_at(
           eth_fork_schedule:configured_network(), Fork) of
        {ok, From} -> Timestamp >= From;
        %% A network that does not timestamp this fork. Reporting "not yet
        %% activated" would make V2 demand the V1 structure forever on it, so this
        %% is answered as "already active", which is the reading that leaves the
        %% V2 structure -- the one that carries withdrawals, and so the superset --
        %% in place.
        error -> true
    end.

%% The fork a method of the given version is the method *for*. This is the fork
%% whose time frame bounds the method, which is not the same as the structure the
%% method demands: V2's structure is chosen by the timestamp, and V2 has no upper
%% bound of its own.
-spec version_fork(integer()) -> atom().
version_fork(1) -> paris;
version_fork(2) -> shanghai;
version_fork(3) -> cancun;
version_fork(4) -> prague;
%% **There is no `getPayloadV5`.** The documents name `engine_getPayloadV4` (prague.md) and
%% `engine_getPayloadV6` (amsterdam.md), and nothing between them, so version 5 has no clause
%% here on purpose: an unmapped version is refused rather than answered with a neighbour's
%% structure, which is the failure this module has committed to twice already.
version_fork(6) -> amsterdam.

%% ok | {error, Code, Message}
-spec payload_admission(map() | term(), integer()) -> ok | {error, integer(), binary()}.
payload_admission(Payload, 1) when is_map(Payload) ->
    %% V1 has no parameter gate at all, and this is worth being explicit about
    %% because it is the opposite of what the V3 clause says one clause earlier.
    %% src/engine/paris.md, engine_newPayloadV1, lists six specification items and
    %% not one of them is a structure check; the string `-32602' does not occur in
    %% paris.md anywhere. The structure requirement arrives with V2
    %% (src/engine/shanghai.md: "MUST return -32602: Invalid params error if the
    %% wrong version of the structure is used") and is restated for V3
    %% (src/engine/cancun.md item 1: "strictly matches the expected one").
    %
    %% So applying a structure check to V1 would refuse a Cancun payload sent to
    %% newPayloadV1 with an error code the Paris method has no clause to produce.
    %% A consensus layer client does not do that -- it calls the method matching
    %% the fork -- so a V1 call carrying a later structure is a client that has
    %% been told to use V3, not a request this node should refuse on a code the
    %% specification does not define for it.
    ok;
payload_admission(Payload, Version) when is_map(Payload), is_integer(Version) ->
    case strict_timestamp(Payload) of
        {ok, Timestamp} ->
            Structure = structure_for_version(Version, Timestamp),
            case structure_admission(Payload, Structure) of
                ok -> frame_admission(Version, Timestamp);
                {error, _, _} = Error -> Error
            end;
        error ->
            %% Item 1 is the structure check, and an unreadable timestamp means
            %% the parameters do not match the expected structure. It is not a fork
            %% error, because "does not fall within the time frame" cannot be
            %% evaluated at all -- and V2's structure choice depends on it.
            {error, ?INVALID_PARAMS, <<"invalid params">>}
    end;
payload_admission(_Payload, _Version) ->
    {error, ?INVALID_PARAMS, <<"invalid params">>}.

%% Only V3 carries the -38005 clause. V1 predates it, and V2's only timestamp
%% rule is the structure choice already made above -- the specification puts no
%% upper bound on V2, so imposing one here would refuse payloads the
%% specification says to accept.
frame_admission(1, _Timestamp) -> ok;
frame_admission(2, _Timestamp) -> ok;
frame_admission(3, Timestamp) ->
    case in_fork_frame(cancun, Timestamp) of
        true -> ok;
        false -> {error, ?UNSUPPORTED_FORK, <<"unsupported fork">>}
    end;
%% **`-38005 Unsupported fork`, and each method is gated on the fork it was introduced for.**
%%
%% My first pass gated V4 and V5 both at `prague', reasoning that "ExecutionPayloadV4 exists
%% from Prague onwards". The test answered `-38005' for a post-Amsterdam timestamp, and it
%% was right to: **`in_fork_frame/2` asks whether the timestamp falls *between* this fork and
%% the next**, so a Prague frame ends when Osaka activates. Gating the Amsterdam method at
%% Prague refuses every timestamp the method exists to serve.
%%
%% The method number and the payload structure number are different axes, and this is where
%% that shows: `newPayloadV4` is Prague's method over a **V3-shaped** payload, and
%% `newPayloadV5` is Amsterdam's over a **V4-shaped** one. Hence `structure_for_version/2`
%% maps 4 to `cancun` and 5 to `amsterdam` -- the payload, not the fork -- while this maps 4
%% to `prague` and 5 to `amsterdam` -- the fork.
frame_admission(4, Timestamp) ->
    case in_fork_frame(prague, Timestamp) of
        true -> ok;
        false -> {error, ?UNSUPPORTED_FORK, <<"unsupported fork">>}
    end;
frame_admission(5, Timestamp) ->
    case in_fork_frame(amsterdam, Timestamp) of
        true -> ok;
        false -> {error, ?UNSUPPORTED_FORK, <<"unsupported fork">>}
    end.

in_fork_frame(Fork, Timestamp) ->
    eth_fork_schedule:timestamp_in_frame(
      eth_fork_schedule:configured_network(), Fork, Timestamp).

%% The set of appended keys the payload carries, sorted, must equal the set its
%% version requires, sorted. `null' counts as absent per item 1.
structure_admission(Payload, Structure) ->
    Expected = lists:sort(required_structure(Structure)),
    case lists:sort([K || K <- appended_keys(), present(Payload, K)]) of
        Expected -> ok;
        Actual -> {error, ?INVALID_PARAMS, structure_message(Expected, Actual)}
    end.

%% "Any field having `null' value MUST be considered as not provided."
present(Payload, Key) ->
    case maps:find(Key, Payload) of
        {ok, null} -> false;
        {ok, undefined} -> false;
        {ok, _Value} -> true;
        error -> false
    end.

structure_message([], []) -> <<"invalid params">>;
structure_message([], Actual) ->
    iolist_to_binary(["invalid params: unexpected ",
                      lists:join(", ", key_names(Actual))]);
structure_message(Expected, []) ->
    iolist_to_binary(["invalid params: missing ",
                      lists:join(", ", key_names(Expected))]);
structure_message(Expected, Actual) ->
    iolist_to_binary(["invalid params: expected ",
                      lists:join(", ", key_names(Expected)),
                      " but got ", lists:join(", ", key_names(Actual))]).

key_names(Keys) -> [binary_to_list(K) || K <- lists:sort(Keys)].

%% A QUANTITY read strictly. This is deliberately not quantity/2, which answers
%% its Default for an unparseable value: the -32602 gate has to be able to tell
%% "the client sent 0x0" from "the client sent something I cannot read", and
%% defaulting the second to the first would report a missing field for a payload
%% that carries one.
strict_timestamp(Payload) ->
    case maps:find(<<"timestamp">>, Payload) of
        {ok, null} -> error;
        {ok, undefined} -> error;
        {ok, Value} -> strict_quantity(Value);
        error -> error
    end.

strict_quantity(Value) when is_integer(Value), Value >= 0 -> {ok, Value};
strict_quantity(Value) when is_binary(Value) ->
    try {ok, eth_hex:decode(Value)} catch _:_ -> error end;
strict_quantity(_Value) -> error.

%% ---------------------------------------------------------------------------
%% payloadAttributes admission
%% ---------------------------------------------------------------------------
%%
%% From execution-apis src/engine/cancun.md, engine_forkchoiceUpdatedV3 item 2,
%% which "Extend[s] point (8) of the engine_forkchoiceUpdatedV1 specification by
%% defining the following sequence of checks that MUST be run over
%% payloadAttributes":
%%
%%   1. "payloadAttributes matches the PayloadAttributesV3 structure, return
%%      -38003: Invalid payload attributes on failure."
%%   2. "payloadAttributes.timestamp does not fall within the time frame of the
%%      Cancun fork, return -38005: Unsupported fork on failure."
%%
%% Note the two different codes: a *malformed* attributes object is -38003, and
%% a well-formed one aimed at the wrong fork is -38005. Collapsing them would
%% leave a client unable to tell "you sent me the wrong shape" from "you sent me
%% the right shape for the wrong time", and the second is retryable on a
%% different method while the first is not.
%%
%% PayloadAttributesV1 is timestamp, prevRandao and suggestedFeeRecipient;
%% V2 appends withdrawals (src/engine/shanghai.md, PayloadAttributesV2) and V3
%% appends parentBeaconBlockRoot (src/engine/cancun.md, PayloadAttributesV3). So
%% the keys that identify a version are the appended ones, and the same
%% exact-set rule applies for the same reason.
-spec attributes_admission(map() | null | term(), integer()) -> ok | {error, integer(), binary()}.
attributes_admission(null, _Version) -> ok;
attributes_admission(undefined, _Version) -> ok;
attributes_admission(_Attributes, 1) ->
    %% V1 has no structure check either, for the same reason the payload gate does
    %% not: -32602 does not occur in paris.md. The one attributes rule Paris does
    %% have is point (8).1 -- "Verify that payloadAttributes.timestamp is greater
    %% than timestamp of a block referenced by forkchoiceState.headBlockHash and
    %% return -38003 on failure" -- which needs the head's timestamp and so belongs
    %% to the forkchoice path, not to a check on the attributes alone. This node
    %% does not have the head's block, so that check is unwired rather than
    %% approximated here; see the note in forkchoice_updated/1.
    ok;
attributes_admission(Attributes, Version) when is_map(Attributes), is_integer(Version) ->
    Structure = version_fork(Version),
    Expected = lists:sort(required_attributes(Structure)),
    case lists:sort([K || K <- appended_attribute_keys(), present(Attributes, K)]) of
        Expected -> attributes_frame_admission(Attributes, Version);
        Actual -> {error, ?INVALID_ATTRIBUTES,
                   attributes_message(Expected, Actual)}
    end;
attributes_admission(_Attributes, _Version) ->
    {error, ?INVALID_ATTRIBUTES, <<"invalid payload attributes">>}.

attributes_message(Expected, Actual) ->
    case {Expected, Actual} of
        {[], []} -> <<"invalid payload attributes">>;
        {[], _} -> iolist_to_binary(["invalid payload attributes: unexpected ",
                                     lists:join(", ", key_names(Actual))]);
        {_, []} -> iolist_to_binary(["invalid payload attributes: missing ",
                                     lists:join(", ", key_names(Expected))]);
        _ -> iolist_to_binary(["invalid payload attributes: expected ",
                               lists:join(", ", key_names(Expected)),
                               " but got ", lists:join(", ", key_names(Actual))])
    end.

%% The attributes' own timestamp is the one that must be in frame, not the
%% head's: it is the timestamp the *new* block would carry, so it is what decides
%% the fork being built for.
attributes_frame_admission(_Attributes, 1) -> ok;
attributes_frame_admission(_Attributes, 2) -> ok;
attributes_frame_admission(Attributes, 3) ->
    case strict_quantity_field(Attributes, <<"timestamp">>) of
        {ok, Timestamp} -> frame_admission(3, Timestamp);
        error ->
            %% A QUANTITY is checked as part of matching the structure, so an
            %% unreadable one is a shape failure, and the code is -38003.
            {error, ?INVALID_ATTRIBUTES,
             <<"invalid payload attributes: timestamp">>}
    end;
attributes_frame_admission(Attributes, 4) ->
    attributes_frame_check(Attributes, prague);
%% **`getPayloadV6` is gated on `amsterdam` and not on `6`.** There is no `getPayloadV5`,
%% so the method numbers and the fork numbers drift apart, and forwarding the version
%% straight into `frame_admission/2` -- which is what this did -- raises `function_clause`
%% on the first V6 attributes object. **Two version axes, and only one of them is a fork.**
attributes_frame_admission(Attributes, 6) ->
    attributes_frame_check(Attributes, amsterdam).

attributes_frame_check(Attributes, Fork) ->
    %% The same timestamp gate the payload methods use, and for the same reason: a
    %% `PayloadAttributesV4` arriving at a pre-Amsterdam timestamp is a client using the
    %% wrong version, and `-38005` is the code the specification defines for that.
    case strict_quantity_field(Attributes, <<"timestamp">>) of
        {ok, Timestamp} ->
            %% **A boolean is not an answer `attributes_admission/2` can carry.** It matches
            %% `ok' and `{error, Code, Message}' and nothing else, so returning
            %% `in_fork_frame/2`'s `false' made every pre-fork attributes object look like
            %% a success -- a refusal that reads as an acceptance.
            case in_fork_frame(Fork, Timestamp) of
                true -> ok;
                false -> {error, ?UNSUPPORTED_FORK, <<"unsupported fork">>}
            end;
        error ->
            {error, ?INVALID_ATTRIBUTES,
             <<"invalid payload attributes: timestamp">>}
    end.

strict_quantity_field(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> strict_quantity(Value);
        error -> error
    end.

%% ---------------------------------------------------------------------------
%% Blob versioned hashes (newPayloadV3)
%% ---------------------------------------------------------------------------
%%
%% execution-apis src/engine/cancun.md, engine_newPayloadV3 item 3:
%%
%%   1. "Obtain the actual array by concatenating blob versioned hashes lists
%%      (tx.blob_versioned_hashes) of each blob transaction included in the
%%      payload, respecting the order of inclusion. If the payload has no blob
%%      transactions the expected array MUST be []."
%%   2. "Return {status: INVALID, latestValidHash: null, validationError:
%%      errorMessage | null} if the expected and the actual arrays don't match."
%%   3. "This validation MUST be instantly run in all cases even during active sync
%%      process."
%%
%% Item 3 is the reason this is a separate function and not folded into
%% new_payload/1. Everything else in this module answers SYNCING when it holds no
%% prestate to execute against, and that is the correct answer for a root it
%% cannot compute. It is the wrong answer here: a client that has just been told
%% SYNCING will offer the same payload again, and a payload whose blob hashes
%% disagree with the consensus layer's will disagree forever. So this check runs
%% before the state-dependent path and its result does not depend on whether the
%% node can execute.
%%
%% Note it is a *status* (INVALID), not an error code, unlike the -32602 and
%% -38005 gates above. The payload is well formed and aimed at the right fork; it
%% is the contents that are wrong, so the specification gives it a verdict.

%% ok | {invalid, Expected, Actual} | {unchecked, Reason}
-spec blob_hashes_admission(map() | term(), term()) ->
          ok | {invalid, [binary()], [binary()]} | {unchecked, term()}.
blob_hashes_admission(Payload, Expected) when is_map(Payload) ->
    case expected_hashes(Expected) of
        {ok, ExpectedHashes} ->
            case actual_hashes(Payload) of
                {ok, ActualHashes} ->
                    case ActualHashes =:= ExpectedHashes of
                        true -> ok;
                        false -> {invalid, ExpectedHashes, ActualHashes}
                    end;
                {error, Reason} ->
                    {unchecked, Reason}
            end;
        error ->
            %% The specification calls the expected array a parameter of the
            %% call, and item 1 requires a strict parameter match, so a value
            %% that is not an array of 32-byte hashes has already failed the
            %% -32602 gate. Reaching here means the caller skipped that gate.
            {unchecked, expected_hashes_not_an_array}
    end;
blob_hashes_admission(_Payload, _Expected) ->
    {unchecked, payload_not_an_object}.

expected_hashes(Expected) when is_list(Expected) ->
    Hashes = [expected_hash(H) || H <- Expected],
    case lists:all(fun is_ok_1/1, Hashes) of
        true -> {ok, [H || {ok, H} <- Hashes]};
        false -> error
    end;
expected_hashes(_Expected) -> error.

is_ok_1({ok, _}) -> true;
is_ok_1(_) -> false.

%% A versioned hash arrives as DATA, which on the wire is a 0x-prefixed hex string
%% and in an in-process caller is the 32 raw bytes it denotes. Both are accepted, as
%% eth_block:payload_data/2 accepts both, and a value that is neither -- or that is
%% 32 bytes whose first byte is not 0x01 -- is not a versioned hash.
%%
%% The first byte check is EIP-4844's: the versioned hash is the first byte of the
%% SHA-256 of the commitment, with the version in the top bit, so it is 0x01 for
%% the only version defined. Without it a caller could assert any 32 bytes and be
%% told the payload's blobs matched.
%%
%% The DATA decode is data32/1, which already existed below and already accepts the
%% wire form and the raw form. It is worth saying why, because the first version of
%% this wrote its own decoder on eth_hex:decode/1 -- which returns an *integer*,
%% correct for a QUANTITY and never a 32-byte binary -- and so rejected every
%% well-formed value it was shown, reporting `expected_hashes_not_an_array' for a
%% perfectly good hash. eth_hex has no hex-to-bytes function at all; eth_block's
%% hex_data/1 is now exported for callers that need one.
expected_hash(Hash) when is_binary(Hash) ->
    case data32(Hash) of
        {ok, <<16#01, _/binary>> = Bytes} -> {ok, Bytes};
        {ok, Other} -> {error, Other};
        {error, _} -> {error, Hash}
    end;
expected_hash(_Hash) -> {error, not_data}.

%% The hashes the payload's own blob transactions commit to, in order of
%% inclusion. A transaction this node cannot decode leaves the actual array
%% unknown, and that is reported as unknown rather than as empty: "the payload has
%% no blob transactions" and "this node could not read the transactions" are
%% different claims, and only the first makes the expected array [].
actual_hashes(Payload) ->
    case payload_transactions(Payload) of
        {ok, Transactions} -> actual_hashes_of(Transactions, []);
        error -> {error, transactions_not_an_array}
    end.

payload_transactions(Payload) ->
    case maps:find(<<"transactions">>, Payload) of
        {ok, null} -> error;
        {ok, undefined} -> error;
        {ok, Transactions} when is_list(Transactions) -> {ok, Transactions};
        {ok, _Other} -> error;
        error -> error
    end.

actual_hashes_of([], Acc) -> {ok, lists:reverse(Acc)};
actual_hashes_of([Item | Rest], Acc) ->
    case tx_bytes(Item) of
        {ok, Bytes} ->
            case eth_tx:from_rlp(Bytes) of
                {ok, Tx} ->
                    actual_hashes_of(
                      Rest, lists:reverse(eth_tx:blob_versioned_hashes(Tx)) ++ Acc);
                {error, Reason} ->
                    {error, {undecodable_transaction, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% A payload's transactions are DATA of whatever length the transaction is, so this
%% cannot be data32/1 and is not length-checked against a constant. The hex decode
%% is eth_block:hex_data/1; the first version used eth_hex:decode/1, which returns
%% an *integer*, so every real transaction in every real payload failed the
%% `is_binary' test below and was reported as {bad_transaction, <an integer>}. The
%% consequence was that actual_hashes/1 could never read a real payload, so
%% newPayloadV3 answered SYNCING for a payload whose blob hashes disagree with the
%% consensus layer's -- the exact case the check exists to catch, silently missed
%% on every payload that carried a transaction.
%%
%% Raw bytes are accepted as well, since that is what an in-process caller holds;
%% `eth_block:payload_data/2' accepts both for the same reason.
tx_bytes(Item) when is_binary(Item) ->
    case eth_block:hex_data(Item) of
        {ok, <<>>} -> {error, empty_transaction};
        {ok, Bytes} -> {ok, Bytes};
        error -> {ok, Item}
    end;
tx_bytes(Item) -> {error, {bad_transaction, Item}}.

%% ---------------------------------------------------------------------------
%% Statuses
%% ---------------------------------------------------------------------------
%%
%% One status is version-dependent. From execution-apis src/engine/shanghai.md,
%% engine_newPayloadV2, Response:
%%
%%   "result: PayloadStatusV1, values of the `status' field are restricted in the
%%    following way: `INVALID_BLOCK_HASH' status value is supplanted by `INVALID'."
%%
%% So from V2 onwards a block whose hash does not match its own contents is
%% reported as INVALID, and INVALID_BLOCK_HASH is reserved for V1. This is not a
%% cosmetic rename: INVALID_BLOCK_HASH is the status that tells a client "this is
%% a corrupt payload, not a valid block I chose to reject", and a client that
%% receives it on a V2 method is reading a value the specification withdrew from
%% that method.
-spec status_for_version(binary(), integer()) -> binary().
status_for_version(?INVALID_BLOCK_HASH, 1) -> ?INVALID_BLOCK_HASH;
status_for_version(?INVALID_BLOCK_HASH, _Version) -> ?INVALID;
status_for_version(Status, _Version) -> Status.
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
                case validate_payload(Payload, State) of
                    {ok, Block} ->
                        execute_and_verdict(Block);
                    {error, Status, Why} ->
                        {Status, Why}
                end
            catch
                Class:Reason:Stack ->
                    logger:warning("etherlang: engine new_payload error ~p:~p~n~p",
                                   [Class, Reason, Stack]),
                    {?INVALID, Reason}
            end
    end;
new_payload(_Payload) ->
    {?INVALID, payload_not_an_object}.

%% Everything decidable before execution, in the order the specification lists it.
%%
%% 1. The payload must decode. A payload that does not is INVALID, and there is
%%    nothing to execute.
%% 2. `blockHash' must be the hash of the header the payload's own fields imply.
%%    The specification requires this "in all cases ... even if this branch or any
%%    other branches of the block tree are in an active sync process", and it
%%    comes before execution for the same reason: a payload whose hash does not
%%    match its own contents is not a block, whatever its state root turns out to
%%    be. Its own status for this is INVALID_BLOCK_HASH, which is distinct from
%%    INVALID precisely so a client can tell a corrupt payload from a valid one
%%    this node rejected.
%%
%% The parent hash is deliberately *not* compared against the recorded head as a
%% gate. A payload whose parent is not the head is not invalid -- it is a side
%% branch, or a block this node has not imported -- and the specification answers
%% SYNCING to both. Comparing it could only ever produce a wrong INVALID. It is
%% logged instead, because a client proposing a block on a different parent is
%% worth noticing.
validate_payload(Payload, State) ->
    case eth_block:from_payload(Payload) of
        {error, Reason} ->
            {error, ?INVALID, Reason};
        {ok, Block} ->
            case check_block_hash(Payload) of
                ok ->
                    note_parent(State, Payload),
                    {ok, Block};
                {error, Reason2} ->
                    {error, ?INVALID_BLOCK_HASH, Reason2}
            end
    end.

check_block_hash(Payload) ->
    case data32(field(Payload, "blockHash", undefined)) of
        {error, _} ->
            {error, missing_or_malformed_block_hash};
        {ok, Declared} ->
            case eth_block:payload_block_hash(Payload) of
                {error, Reason} ->
                    {error, Reason};
                {ok, Declared} ->
                    ok;
                {ok, Computed} ->
                    {error, {block_hash_mismatch, Declared, Computed}}
            end
    end.

%% The recorded head is read for the log line only, for the reason given above:
%% a parent that is not the head is not a reason to reject a payload.
note_parent(State, Payload) ->
    Parent = case data32(field(Payload, "parentHash", undefined)) of
        {ok, Bytes} -> Bytes;
        {error, _} -> undefined
    end,
    case {State#st.head, Parent} of
        {undefined, _} -> ok;
        {_Head, undefined} -> ok;
        {Head, Parent} when Head =:= Parent -> ok;
        {Head, Parent} ->
            logger:info("etherlang: engine payload parent ~s is not the recorded head ~s",
                        [fmt(Parent), fmt(Head)])
    end.

%% ---------------------------------------------------------------------------
%% Execution and the verdict
%% ---------------------------------------------------------------------------
%%
%% eth_block:finalize/1 executes the block and reports each of the three roots as
%% a `{verified, Root} | {unverified, Reason}' verdict. This maps those onto the
%% statuses, and the mapping is the whole point: a root this node checked and
%% found wrong is INVALID, and a root it could not check is SYNCING. Reporting
%% both as the same thing -- or reporting SYNCING for a mismatch -- would leave a
%% client unable to tell a block this node has found bad from one it has not
%% finished looking at.
%%
%% The return shape follows the specification's `validationError' rule: a bare
%% status when there is nothing to report, and `{Status, Reason}' only for the
%% statuses the specification allows a reason with, which are INVALID and
%% INVALID_BLOCK_HASH. A reason attached to SYNCING describes this node's
%% position, not a verdict on the payload, and the specification has no field for
%% it -- so it is logged here rather than shown to the client as an error for a
%% block it did nothing wrong.
%%
%% Note that finalize/1 commits the post-state, and is not idempotent. That is
%% correct for this method, which is the one place a payload is meant to be
%% executed, and it is why nothing else in this module calls it.
execute_and_verdict(Block) ->
    status_for_finalize(eth_block:finalize(Block)).

%% The whole mapping from what finalizing produced to what the client is told,
%% as a pure function of that result.
%%
%% It is split out because it is the part with the judgement in it, and the part
%% that is hardest to reach through the module's public API: every path that
%% produces a *checked* verdict needs the parent block's state to be held
%% locally, which is not something a unit test sets up. The other half -- that
%% finalizing produces these verdicts -- is checked where it happens, in
%% eth_finalize_tests, against blocks that execute. Between them the path is
%% covered, and each test says which half it is pinning rather than pretending to
%% have executed a block.
status_for_finalize({error, {unknown_parent, _} = Reason}) ->
    %% The specification's SYNCING: the head references a payload this node does
    %% not have, so it cannot be validated yet.
    unsynced(Reason);
status_for_finalize({error, {invalid_transaction, _Index, _Why} = Reason}) ->
    %% A block whose body contains an invalid transaction is not a block. Not
    %% SYNCING: there is nothing to wait for, the answer will not change.
    {?INVALID, Reason};
status_for_finalize({error, Reason}) ->
    {?INVALID, Reason};
status_for_finalize({ok, _Final, Verification}) ->
    status_for_verification(Verification).

status_for_verification(Verification) ->
    case [V || V <- root_verdicts(Verification),
               eth_block:is_mismatch_verdict(V)] of
        [First | _] ->
            %% Checked, and wrong.
            {?INVALID, First};
        [] ->
            case [V || V <- root_verdicts(Verification), not is_checked(V)] of
                [] ->
                    ?VALID;
                Unchecked ->
                    unsynced({not_verified, Unchecked})
            end
    end.

unsynced(Reason) ->
    logger:info("etherlang: engine new_payload cannot validate yet: ~p", [Reason]),
    ?SYNCING.

root_verdicts(#{state_root := S, transactions_root := T, receipts_root := R}) ->
    [S, T, R].

%% A commitment that was not checked, so the block is not known to be valid.
%%
%% Only this half of the verdict is matched here, and it is matched on the tag
%% rather than on a reason: `{verified, _}' vs `{unverified, _}' is the published
%% shape of a verdict, so it is this module's business. Whether an `unverified'
%% verdict means *wrong* or *absent* is eth_block's -- its reasons are five
%% different terms in three shapes, and matching them from here got the state
%% root's 3-tuple `{mismatch, _, _}' wrong, so a wrong state root was answered
%% SYNCING. See eth_block:is_mismatch_verdict/1.
is_checked({verified, _}) -> true;
is_checked(_) -> false.

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

%% forkchoice_updated/2 is the method a consensus client actually calls, because
%% payloadAttributes is params[1] and this module's one-argument form had nowhere
%% to put it. So the build that the specification describes -- "process
%% payloadAttributes after successfully applying the forkchoiceState" -- could not
%% be expressed at all, and `getPayload' reported every payloadId unknown because
%% none was ever issued.
%%
%% The order is the specification's: apply the forkchoiceState first, and only
%% then act on the attributes, and only if the head is VALID. This node never
%% reports VALID -- it holds no prestate for an arbitrary head, so it answers
%% SYNCING -- and a build is therefore issued unconditionally rather than gated on
%% a validity claim it cannot make. That is a real deviation and it is recorded
%% here rather than hidden: a client is asked for a block on top of a head this
%% node has not validated. The alternative is to never build, which is where this
%% node was.
forkchoice_updated(ForkChoiceState, Attributes) when is_map(ForkChoiceState) ->
    case apply_forkchoice(ForkChoiceState) of
        {error, Reason} ->
            {error, Reason};
        Status ->
            case Attributes of
                null -> {Status, undefined};
                undefined -> {Status, undefined};
                _ ->
                    case start_build(ForkChoiceState, Attributes) of
                        {ok, PayloadId} -> {Status, PayloadId};
                        {error, Reason} -> logger:warning(
                            "etherlang: forkchoiceUpdated could not start a build: ~p",
                            [Reason]),
                                           {Status, undefined}
                    end
            end
    end;
forkchoice_updated(_ForkChoiceState, _Attributes) ->
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
%% get_payload/1 answers a payload this node built, with the `blockValue' the
%% fee recipient is promised.
%%
%% It answered `{error, unknown_payload}' for *every* id, unconditionally, because
%% nothing ever issued one: `eth_block_builder' was not started and
%% `forkchoiceUpdated' had no payloadAttributes handling, so there was no build to
%% collect. The id is validated first -- the specification's parameter is DATA, 8
%% bytes -- and an id of the wrong shape is `invalid_params' rather than
%% `unknown_payload', because "you sent me nonsense" and "I never built that" are
%% different answers and only the first is a client bug.
get_payload(PayloadId) ->
    case data(PayloadId, 8) of
        {ok, Bytes} ->
            case whereis(eth_block_builder) of
                undefined ->
                    %% The builder is not running, so nothing can have been built.
                    %% The old unconditional answer was right for the wrong reason:
                    %% it said "unknown" because it never asked.
                    {error, unknown_payload};
                _Pid ->
                    try eth_block_builder:get_payload(Bytes) of
                        {ok, Payload, BlockValue} ->
                            {ok, Payload, BlockValue};
                        {error, Reason} ->
                            {error, Reason}
                    catch
                        Class:Reason -> {error, {builder_failed, Class, Reason}}
                    end
            end;
        {error, _Why} ->
            {error, invalid_params}
    end.

%% Hand the decoded attributes to the builder and keep the payloadId it issues.
%%
%% The builder being unstarted was not a missing feature but a dead module: it was
%% absent from `etherlang.app.src's registered list and from `etherlang_sup's
%% children, so `whereis(eth_block_builder)' was undefined and every call raised
%% noproc. This checks first and refuses the build with a reason, so a
%% misconfigured node answers SYNCING with a null payloadId -- the same honest
%% answer it gave before -- rather than raising inside the request.
start_build(ForkChoiceState, Attributes) ->
    case whereis(eth_block_builder) of
        undefined ->
            {error, builder_not_running};
        _Pid ->
            case build_attributes(ForkChoiceState, Attributes) of
                {error, Reason} ->
                    {error, Reason};
                {ok, Decoded} ->
                    try eth_block_builder:build(Decoded) of
                        {ok, Payload, BlockValue} ->
                            store_payload(Payload, BlockValue);
                        {error, Reason} ->
                            {error, Reason}
                    catch
                        Class:Reason ->
                            {error, {build_crashed, Class, Reason}}
                    end
            end
    end.

%% The builder owns the payloadId store -- it is the thing that issues and serves
%% them -- so this goes through its gen_server rather than keeping a second copy
%% here. Two stores would answer getPayload from whichever the caller happened to
%% reach, and the CL would get "unknown payload" for an id it was just given.
store_payload(Payload, BlockValue) ->
    case eth_block_builder:store_payload(Payload, BlockValue) of
        {ok, PayloadId} ->
            logger:info("etherlang: issued engine payloadId for a block this node "
                        "built; its state root is not expected to match the "
                        "network's while the per-fork gas table is unwired"),
            {ok, PayloadId};
        {error, Reason} ->
            {error, Reason}
    end.

%% Turn the client's payloadAttributes into the decoded form
%% eth_block_builder:build/1 takes: raw bytes and integers, not the JSON strings
%% the Engine API carries. Decoding happens here rather than in the builder
%% because this module already decodes the attributes for the admission checks, and
%% a second decoder is a second place for a field to be read wrongly.
%%
%% Three of the values are not in payloadAttributes at all and are read from the
%% parent block, which the chain store already holds:
%%
%%   number       the head's height. payloadAttributes carries no number, and the
%%                fork that applies to the block being built is partly decided by
%%                it. Guessing 0 would build a block for the genesis slot.
%%   gasLimit     the parent's. EIP-1559's base-fee formula divides by it, so a
%%                constant here would compute a base fee the network does not use.
%%   baseFeePerGas  the parent's own base fee, which is the formula's other input.
%%
%% If the chain does not hold the head, there is no honest value for any of the
%% three, so this is an error and the build is refused. A node that does not have
%% the block a client wants built on top of cannot build on it, and returning a
%% payloadId anyway would start a build whose base fee is a guess -- which is the
%% first field of the header and the one every fee calculation then divides by.
-spec build_attributes(map(), map()) -> {ok, map()} | {error, term()}.
build_attributes(ForkChoiceState, Attributes) when is_map(Attributes) ->
    case data(field(ForkChoiceState, "headBlockHash", undefined), 32) of
        {ok, ParentHash} ->
            case parent_fields(ParentHash) of
                {error, Reason} ->
                    {error, Reason};
                {ok, Parent} ->
                    with_attributes(Parent, Attributes)
            end;
        {error, Reason} ->
            {error, {bad_head, Reason}}
    end;
build_attributes(_ForkChoiceState, _Attributes) ->
    {error, attributes_not_an_object}.

%% The parent block as the chain store holds it. That is the `eth_getBlockByNumber`
%% response, i.e. a map with hex quantities -- not a #block{} record -- so these are
%% read from the map with strict decoders and no defaults. A missing or unreadable
%% value is an error, because every use of it would otherwise be a number this node
%% made up.
%% eth_chain is keyed by the `hash' field of the block map it stores, which is the
%% 0x-prefixed hex string an eth_getBlockByNumber response carries -- not the 32 raw
%% bytes every other hash in this codebase is held as. So the key has to be
%% re-encoded, and getting this wrong does not raise: `get_by_hash' answers
%% `not_found', the build is refused, and `forkchoiceUpdated' reports a null
%% payloadId. That is the honest answer for a node that cannot find the block, so
%% the failure is silent -- and it is why this was worth writing down rather than
%% discovering through a null payloadId.
%%
%% eth_block:parent_state_root/1 bridges the same gap for the same reason, and
%% eth_eth's three callers pass a variable they named `Hex'.
parent_fields(ParentHash) ->
    try eth_chain:get_by_hash(eth_hex:encode_bytes(ParentHash)) of
        {ok, Block, _Full} when is_map(Block) ->
            Num = strict_quantity(maps:get(<<"number">>, Block, undefined)),
            GasLimit = strict_quantity(maps:get(<<"gasLimit">>, Block, undefined)),
            BaseFee = strict_quantity(maps:get(<<"baseFeePerGas">>, Block,
                                               undefined)),
            %% EIP-4844's two inputs, for the same reason as the three above: the
            %% header's excessBlobGas is the parent's excess plus the gas the
            %% parent's blobs used, less the per-block target. Defaulting it to 0
            %% would be a consensus value this node invented, and a Cancun header
            %% carries it -- so a build on top of a parent that used blobs would
            %% commit to an excess the network did not compute.
            ParentExcess = strict_quantity(maps:get(<<"excessBlobGas">>, Block,
                                                    undefined)),
            ParentBlobGas = strict_quantity(maps:get(<<"blobGasUsed">>, Block,
                                                     undefined)),
            case {Num, GasLimit, BaseFee, ParentExcess, ParentBlobGas} of
                {{ok, N}, {ok, GL}, {ok, BF}, {ok, PE}, {ok, PB}} ->
                    %% The block being built is the *child*, so its number is one
                    %% above the head's. Passing the head's own number through built a
                    %% block at its parent's height -- visible only in the log line
                    %% this module writes ("built block 0" for a block on top of
                    %% block 0), because a block that duplicates its parent's height
                    %% hashes without complaint and no assertion was reading it.
                    {ok, #{parent_hash => ParentHash, number => N + 1,
                           gas_limit => GL, base_fee => BF,
                           parent_excess_blob_gas => PE,
                           parent_blob_gas_used => PB,
                           %% EIP-7918: `calc_excess_blob_gas` compares a reserve price
                           %% built from the *parent's* base fee. `BaseFee` above is read
                           %% from the same header as `PE` and `PB`, so it is the parent's,
                           %% not the block being built's -- which is what the rule asks for.
                           parent_base_fee_per_gas => BF}};
                Other ->
                    {error, {unreadable_parent, Other}}
            end;
        _ ->
            {error, head_not_held}
    catch
        _:_ -> {error, chain_unavailable}
    end.

%% The client's attributes land on top of the parent's. Each is decoded strictly
%% and a value that will not decode is an error rather than a default: a
%% `prevRandao' read as zero is indistinguishable on the wire from a client that
%% sent zero, and a `timestamp' read as 0 would build a block for the genesis slot.
%%
%% The attribute key set is the one PayloadAttributesV1/V2/V3 defines, and the
%% version's *own* keys -- the admission check in eth_engine has already refused a
%% set that does not match -- so there is nothing to select here: every key present
%% is a key the version defines.
with_attributes(Parent, Attributes) ->
    Fields = [{timestamp, fun attr_quantity/1, 0},
              {prev_randao, fun attr_data_32/1, <<0:256>>},
              {fee_recipient, fun attr_data_20/1, <<0:160>>},
              {withdrawals, fun attr_withdrawals/1, []},
              {parent_beacon_block_root, fun attr_beacon_root/1, undefined}],
    try
        {ok, lists:foldl(
               fun({Key, Read, Default}, Acc) ->
                   case maps:find(Key, Attributes) of
                       error -> maps:put(Key, Default, Acc);
                       {ok, null} -> maps:put(Key, Default, Acc);
                       {ok, Value} -> maps:put(Key, Read(Value), Acc)
                   end
               end, Parent, Fields)}
    catch
        throw:{bad_attribute, Key, Reason} -> {error, {bad_attribute, Key, Reason}}
    end.

attr_quantity(V) ->
    case strict_quantity(V) of
        {ok, N} -> N;
        error -> throw({bad_attribute, <<"timestamp">>, bad_quantity})
    end.

attr_data_32(V) ->
    case data(V, 32) of
        {ok, Bytes} -> Bytes;
        {error, _} -> throw({bad_attribute, <<"prevRandao">>, bad_data})
    end.

attr_data_20(V) ->
    case data(V, 20) of
        {ok, Bytes} -> Bytes;
        {error, _} -> throw({bad_attribute, <<"suggestedFeeRecipient">>, bad_data})
    end.

attr_withdrawals(V) when is_list(V) -> V;
attr_withdrawals(_V) ->
    throw({bad_attribute, <<"withdrawals">>, not_a_list}).

%% A V1 build has no beacon root and must not be given one: a Cancun header field
%% on a Paris block is a field the encoder does not emit, so the value would be
%% carried in a block whose hash never commits to it. The version's own attributes
%% are the authority on whether the field exists -- the admission check refuses a V1
%% attributes object that carries one -- so absence here is absence.
attr_beacon_root(V) ->
    case data(V, 32) of
        {ok, Bytes} -> Bytes;
        {error, _} -> throw({bad_attribute, <<"parentBeaconBlockRoot">>, bad_data})
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
%% sentinel the specification mandates for an undecided value -- raised
%% badarg and the catch turned it into SECURITY_ERROR. The transition
%% configuration could therefore never be exchanged for any network. It is a hex
%% quantity by specification, so it is decoded as one.
%%
%% The configuration map was also built from the *previous* state's values rather
%% than the ones just parsed, so what the node recorded was always one exchange
%% out of date -- and the specification has the client receive these values back
%% from this call, so the staleness was visible to the consensus client.
%%

%% The sentinel for an undecided TERMINAL_TOTAL_DIFFICULTY.
%%
%% This was 2^256-1 (16#ffff...ff, 64 f's). The specification mandates
%% 2^256-2^10, which is 1023 smaller, and the comment above it purported to quote
%% the clause while quoting a *truncated prefix* of the number -- the final
%% "38912" was missing, so the quoted string was both the wrong value and a
%% misquotation. The clause is execution-apis src/engine/paris.md item 7, which
%% reads in full:
%%
%%   7. Considering the absence of the `TERMINAL_TOTAL_DIFFICULTY` value (i.e.
%%      when a value has not been decided), Consensus Layer and Execution Layer
%%      client software **MUST** use
%%      `115792089237316195423570985008687907853269984665640564039457584007913129638912`
%%      value (equal to `2**256-2**10`) for the `terminalTotalDifficulty` input
%%      parameter of this call.
%%
%% The CL compares this value to decide the fork is undecided, so a node that
%% reports 2^256-1 here disagrees with the CL about a consensus parameter and the
%% two can reach different conclusions about when the Merge happened. It is
%% written as 2^256-1024 rather than as the literal decimal so the intent is
%% checkable by reading it, and eth_engine_tests pins the exact decimal string.
-define(NO_TERMINAL_TOTAL_DIFFICULTY,
        ((1 bsl 256) - 1024)).

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
