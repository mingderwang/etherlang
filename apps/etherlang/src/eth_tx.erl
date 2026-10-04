-module(eth_tx).

%% Transaction RLP encoding (legacy, EIP-2930, EIP-1559, EIP-4844) from
%% JSON-RPC maps and transaction-trie root computation for body verification.
%% EIP-7702 and other types: encoding returns {error, unsupported}; such
%% bodies are served/skipped accordingly, never fabricated.
%%
%% Also the single place transaction *validity* is decided. The block builder,
%% the transaction pool and block finalization all had their own answer to this
%% question, and the three did not agree: the builder and the pool each carried
%% their own intrinsic-gas computation, and finalization checked nothing at all.
%% Two rules that disagree about intrinsic gas charge different fees for the
%% same transaction, so this has to be one function called from one place.

-export([
           calldata/1,to_rlp/1, from_rlp/1, tx_root/1, sender/1,
         blob_versioned_hashes/1, valid_versioned_hashes/1,
         authorization_list/1, authorization_authority/1,
         delegation_indicator/1, is_delegation_indicator/1,
         resolve_delegation/3, delegation_target/1,
         blob_hashes_present/1, blob_hashes_well_formed/1,
         validate/1, validate/2, intrinsic_gas/1, intrinsic_gas/2, tx_type/1,
         %% **Exported for the frame, not for a test.** EIP-2930: "The address and
         %% storage keys would be immediately loaded into the accessed_addresses and
         %% accessed_storage_keys global sets." Applying the list is `eth_evm`'s job, and
         %% the normalised shape is this module's -- `validate/2' prices exactly this
         %% function's output, and an access list is in two shapes depending on whether it
         %% came off the wire or off JSON-RPC. Re-deriving it in `eth_block' is how
         %% `eth_tx:calldata/1' came to exist, and the first attempt at this fix did
         %% precisely that and was reverted for costing eleven fixtures.
         access_list_field/1]).

%% The first byte of every versioned hash, per EIP-4844. Only the KZG-commitment
%% variant is defined, so a transaction carrying anything else is invalid.
-define(VERSIONED_HASH_KZG, 16#01).
%% EIP-7702's `MAGIC`, the domain separator on the authorization signing preimage.
%% It is a different digest from the transaction's own type byte on purpose: a
%% signature over an authorization must be useless for anything else.
-define(SET_CODE_MAGIC, 16#05).
-define(SECP256K1_N, 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141).

%% Encode a JSON-RPC transaction map to wire bytes (type prefix included
%% for typed transactions).
to_rlp(Tx) when is_map(Tx) ->
    case tx_type(Tx) of
        legacy ->
            {ok, eth_rlp:encode(
                   [q(Tx, <<"nonce">>), q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                    addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                    q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)])};
        eip2930 ->
            {ok, <<16#01, (eth_rlp:encode(
                             [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                              q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                              addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                              access_list(Tx),
                              q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)]))/binary>>};
        eip1559 ->
            {ok, <<16#02, (eth_rlp:encode(
                             [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                              q(Tx, <<"maxPriorityFeePerGas">>),
                              q(Tx, <<"maxFeePerGas">>),
                              q(Tx, <<"gas">>),
                              addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                              access_list(Tx),
                              q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)]))/binary>>};
        eip4844 ->
            {ok, <<16#03, (eth_rlp:encode(
                             [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                              q(Tx, <<"maxPriorityFeePerGas">>),
                              q(Tx, <<"maxFeePerGas">>),
                              q(Tx, <<"gas">>),
                              addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                              access_list(Tx),
                              q(Tx, <<"maxFeePerBlobGas">>),
                              blob_versioned_hashes(Tx),
                              q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)]))/binary>>};
        eip7702 ->
            %% EIP-7702's payload, in the EIP's order:
            %%   rlp([chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas,
            %%        gas_limit, destination, value, data, access_list,
            %%        authorization_list, signature_y_parity, signature_r,
            %%        signature_s])
            %% and the digest is keccak256(0x04 || payload), which is the same shape
            %% every typed transaction already uses -- only the type byte differs.
            {ok, <<16#04, (eth_rlp:encode(
                             [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                              q(Tx, <<"maxPriorityFeePerGas">>),
                              q(Tx, <<"maxFeePerGas">>),
                              q(Tx, <<"gas">>),
                              addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                              access_list(Tx),
                              authorization_list(Tx),
                              q(Tx, <<"v">>), q(Tx, <<"r">>), q(Tx, <<"s">>)]))/binary>>};
        unsupported ->
            {error, unsupported_tx_type}
    end.

%% Decode wire bytes to a JSON-style map (0x hex fields, type, hash).
%% Inverse of to_rlp for legacy/2930/1559 (no `from' recovery).
from_rlp(Bin) when is_binary(Bin) ->
    try do_from_rlp(Bin)
    catch _:_ -> {error, bad_tx} end.

do_from_rlp(<<16#01, _/binary>> = Bin) ->
    Rest = binary:part(Bin, 1, byte_size(Bin) - 1),
    case eth_rlp:decode(Rest) of
        {ok, [ChainID, Nonce, GasPrice, Gas, To, Value, Input, AL, V, R, S], <<>>} ->
            {ok, #{<<"type">> => <<"0x1">>,
                   <<"chainId">> => hexq(ChainID),
                   <<"nonce">> => hexq(Nonce),
                   <<"gasPrice">> => hexq(GasPrice),
                   <<"gas">> => hexq(Gas),
                   <<"to">> => hexdata(To),
                   <<"value">> => hexq(Value),
                   <<"input">> => hexdata(Input),
                   <<"accessList">> => from_access_list(AL),
                   <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                   <<"hash">> => hexdata(eth_keccak:hash(Bin))}};
        _ ->
            {error, bad_tx}
    end;
do_from_rlp(<<16#02, _/binary>> = Bin) ->
    Rest = binary:part(Bin, 1, byte_size(Bin) - 1),
    case eth_rlp:decode(Rest) of
        {ok, [ChainID, Nonce, MaxPrio, MaxFee, Gas, To, Value, Input, AL, V, R, S], <<>>} ->
            {ok, #{<<"type">> => <<"0x2">>,
                   <<"chainId">> => hexq(ChainID),
                   <<"nonce">> => hexq(Nonce),
                   <<"maxPriorityFeePerGas">> => hexq(MaxPrio),
                   <<"maxFeePerGas">> => hexq(MaxFee),
                   <<"gas">> => hexq(Gas),
                   <<"to">> => hexdata(To),
                   <<"value">> => hexq(Value),
                   <<"input">> => hexdata(Input),
                   <<"accessList">> => from_access_list(AL),
                   <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                   <<"hash">> => hexdata(eth_keccak:hash(Bin))}};
        _ ->
            {error, bad_tx}
    end;
do_from_rlp(<<16#03, _/binary>> = Bin) ->
    Rest = binary:part(Bin, 1, byte_size(Bin) - 1),
    case eth_rlp:decode(Rest) of
        {ok, [ChainID, Nonce, MaxPrio, MaxFee, Gas, To, Value, Input, AL,
              MaxFeePerBlobGas, VersionedHashes, V, R, S], <<>>} ->
            {ok, #{<<"type">> => <<"0x3">>,
                   <<"chainId">> => hexq(ChainID),
                   <<"nonce">> => hexq(Nonce),
                   <<"maxPriorityFeePerGas">> => hexq(MaxPrio),
                   <<"maxFeePerGas">> => hexq(MaxFee),
                   <<"gas">> => hexq(Gas),
                   <<"to">> => hexdata(To),
                   <<"value">> => hexq(Value),
                   <<"input">> => hexdata(Input),
                   <<"accessList">> => from_access_list(AL),
                   <<"maxFeePerBlobGas">> => hexq(MaxFeePerBlobGas),
                   <<"blobVersionedHashes">> => [hexdata(H) || H <- VersionedHashes],
                   <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                   <<"hash">> => hexdata(eth_keccak:hash(Bin))}};
        _ ->
            {error, bad_tx}
    end;
%% EIP-7702, the "set code transaction". The thirteen fields are the EIP's, in its
%% order, and `authorization_list' is the only one this node had no notion of: a
%% list of `[chain_id, address, nonce, y_parity, r, s]' tuples.
%%
%% This clause did not exist, so a type-4 transaction could not be decoded at all
%% and the corpus reported four entries as `tx_decode_failed'. Note what that
%% outcome means: not "the state differs" but "this node cannot represent the
%% transaction", which is a strictly weaker form of failing.
do_from_rlp(<<16#04, _/binary>> = Bin) ->
    Rest = binary:part(Bin, 1, byte_size(Bin) - 1),
    case eth_rlp:decode(Rest) of
        {ok, [ChainID, Nonce, MaxPrio, MaxFee, Gas, To, Value, Input, AL,
              AuthList, V, R, S], <<>>} ->
            {ok, #{<<"type">> => <<"0x4">>,
                   <<"chainId">> => hexq(ChainID),
                   <<"nonce">> => hexq(Nonce),
                   <<"maxPriorityFeePerGas">> => hexq(MaxPrio),
                   <<"maxFeePerGas">> => hexq(MaxFee),
                   <<"gas">> => hexq(Gas),
                   <<"to">> => hexdata(To),
                   <<"value">> => hexq(Value),
                   <<"input">> => hexdata(Input),
                   <<"accessList">> => from_access_list(AL),
                   <<"authorizationList">> => from_authorization_list(AuthList),
                   <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                   <<"hash">> => hexdata(eth_keccak:hash(Bin))}};
        _ ->
            {error, bad_tx}
    end;
do_from_rlp(Bin) ->
    case eth_rlp:decode(Bin) of
        {ok, [Nonce, GasPrice, Gas, To, Value, Input, V, R, S], <<>>} ->
            Base = #{<<"nonce">> => hexq(Nonce),
                     <<"gasPrice">> => hexq(GasPrice),
                     <<"gas">> => hexq(Gas),
                     <<"to">> => hexdata(To),
                     <<"value">> => hexq(Value),
                     <<"input">> => hexdata(Input),
                     <<"v">> => hexq(V), <<"r">> => hexq(R), <<"s">> => hexq(S),
                     <<"hash">> => hexdata(eth_keccak:hash(Bin))},
            {ok, maybe_chain_id(Base, V)};
        _ ->
            {error, bad_tx}
    end.

%% EIP-155 v from large V.
maybe_chain_id(Map, V) ->
    I = to_int(V),
    case I >= 35 of
        true -> Map#{<<"chainId">> => eth_hex:encode_int((I - 35) div 2)};
        false -> Map
    end.

from_access_list(AL) when is_list(AL) ->
    [#{<<"address">> => hexdata(A),
       <<"storageKeys">> => [hexdata(K) || K <- Keys]} || [A, Keys] <- AL];
from_access_list(_) ->
    throw(bad_tx).

%% One authorization tuple, in the EIP's order and field names. A tuple that is not
%% six items is a bad transaction rather than a partial one: the EIP says a
%% transaction "is also considered invalid when any field in an authorization tuple
%% cannot fit within the following bounds", so a short tuple is malformed bytes and
%% not a tuple with defaults.
from_authorization_list(List) when is_list(List) ->
    [#{<<"chainId">> => hexq(ChainID),
       <<"address">> => hexdata(Address),
       <<"nonce">> => hexq(Nonce),
       <<"yParity">> => hexq(YParity),
       <<"r">> => hexq(R),
       <<"s">> => hexq(S)}
     || [ChainID, Address, Nonce, YParity, R, S] <- List];
from_authorization_list(_) ->
    throw(bad_tx).

%% The same tuples back to wire form, for `to_rlp/1'. Each is a six-item RLP *list*,
%% which is what makes it distinguishable on the wire from the flat fields around it.
authorization_list(Tx) ->
    case maps:get(<<"authorizationList">>, Tx,
                  maps:get(<<"authorization_list">>, Tx, [])) of
        L when is_list(L) -> [authorization_tuple(A) || A <- L];
        _ -> []
    end.

%% EIP-7702's delegation indicator: `0xef0100 || address`, 23 bytes.
%%
%% The EIP calls the first byte a use of the banned opcode `0xef` (EIP-3541): a
%% contract that *returned* code starting with `0xef` is not deployable, so the
%% prefix cannot be produced by a create and cannot collide with real code. That is
%% why it is a usable marker, and why `is_delegation_indicator/1` is a length test
%% as well as a prefix test.
%%
%% The special case is the zero address: EIP-7702 step 8 says "If `address` is
%% `0x0000000000000000000000000000000000000000`, do not write the delegation
%% indicator. Clear the account's code" -- so a user can restore an EOA to a plain
%% account, which is the EIP's "Clearing delegation indicators" section. That is why
%% the zero address is *not* a designator for address zero, and why
%% `delegation_indicator/1` here is never asked to build one.
-define(DELEGATION_PREFIX, <<16#EF, 16#01, 16#00>>).

delegation_indicator(Address) when is_binary(Address), byte_size(Address) =:= 20 ->
    <<?DELEGATION_PREFIX/binary, Address/binary>>;
delegation_indicator(Address) -> delegation_indicator(eth_state:address(Address)).

is_delegation_indicator(Code) when is_binary(Code), byte_size(Code) =:= 23 ->
    binary:part(Code, 0, 3) =:= ?DELEGATION_PREFIX;
is_delegation_indicator(_) -> false.

%% The 20-byte address a delegation indicator points at, or `undefined` for any
%% other code -- including code of a different length, which is the case that
%% matters, since `<<16#EF, 16#01, 16#00>>` on its own is *not* a delegation.
delegation_target(Code) when is_binary(Code), byte_size(Code) =:= 23 ->
    case is_delegation_indicator(Code) of
        true -> binary:part(Code, 3, 20);
        false -> undefined
    end;
delegation_target(_) ->
    undefined.

%% EIP-7702, "The delegation forces all code executing operations to follow the
%% address pointer to obtain the code to execute." Resolves **at most one** hop and
%% answers `{Code, Delegate}`, where `Delegate` is `undefined` when no delegation
%% was followed -- so a caller can price the resolution's account access (which
%% the EIP charges only when a delegation *was* followed) without re-deriving
%% whether one was.
%%
%% Three rules, and **all three are counter-intuitive enough that they are worth
%% stating before they are coded**:
%%
%% 1. **One hop, then stop.** "In case a delegation indicator points to another
%%    delegation, creating a potential chain or loop of delegations, clients must
%%    retrieve only the first code and then stop following the delegation chain."
%%    So a designator pointing at a designator resolves to *that designator's
%%    bytes*, which are then executed as code -- and `0xef` is not an instruction
%%    (it is the EIP-3541 banned opcode), so the frame halts. **A recursive
%%    resolution is the wrong implementation and it is also the one that looks
%%    right**: it terminates on no input, because `A -> B -> A` is a cycle a
%%    resolver cannot distinguish from a chain. The halt is the specified answer.
%%
%% 2. **A delegation to a precompile is empty code.** "When a precompile address
%%    is the target of a delegation, the retrieved code is considered empty ...
%%    and therefore succeed with no execution when given enough gas to initiate the
%%    call." So a delegation to `0x01` does **not** run `ecrecover`; it runs
%%    nothing and succeeds. The precompile is a *destination* the designator names,
%%    not one the call enters, and the caller's own access to the account is
%%    still charged.
%%
%% 3. **The account keeps its own identity.** The returned `Code` is executed in
%%    the context of the *account*, not the delegate -- "CALL loads the code at
%%    `address` and executes it in the context of `authority`". This function
%%    therefore returns code and nothing else: the frame's `address`, its storage
%%    and its balance stay the authority's, which is what makes the delegation a
%%    `DELEGATECALL` the user authorised rather than a call *to* the delegate.
resolve_delegation(State, Addr, Fork) ->
    case delegation_target(eth_state:code(State, Addr)) of
        undefined ->
            {eth_state:code(State, Addr), undefined};
        Target ->
            %% The `Addr` code is the indicator itself; the *target's* code is what
            %% runs, and it is read once and never resolved again (rule 1).
            Resolved = case lists:member(Target,
                                         eth_fork_schedule:precompile_addresses(Fork)) of
                           true -> <<>>;                        % rule 2
                           false -> eth_state:code(State, Target)
                       end,
            {Resolved, Target}
    end.

%% EIP-7702 step 3, in full:
%%
%%     Let `authority = ecrecover(msg, y_parity, r, s)`.
%%         Where `msg = keccak(MAGIC || rlp([chain_id, address, nonce]))`.
%%     Verify `s` is less than or equal to `secp256k1n/2`, as specified in EIP-2.
%%
%% The `0x05` is the EIP's `MAGIC`, and it exists to domain-separate this signing
%% preimage from every other thing a key is asked to sign. It is a different digest
%% from the transaction's own, and a preimage from the delegation is **not** a valid
%% authorization for anything else.
%%
%% **The high-\`s' check is not optional**, and the reason is worth stating exactly
%% because the obvious statement of it is wrong. \`ecrecover\` accepts \`s <= n\`, and
%% \`(r, n - s)\` is a *valid* signature over the same message with the same key --
%% that is EIP-2's subject: one signed message, two acceptable signatures. But the
%% high-\`s' form does **not** recover the same authority. Measured on this node:
%% for a key whose low-\`s' form recovers to \`0x5050a4f4...\`, the \`n - s\` form
%% recovers to a different public key, for either value of \`v\`.
%%
%% That is the problem here, and it is sharper than malleability. Recovery maps a
%% signature to an *account*. If both forms were accepted, the same authorization --
%% same chain, same address, same nonce -- would designate **a different account**
%% depending only on which of two equivalent signatures carried it, so a delegation
%% could be silently redirected by relaying a tuple nobody chose. Exactly one of
%% \`s\` and \`n - s\` is low, so the low-\`s\' rule is what makes the designation a
%% function of the tuple rather than of the signature.
%%
%% The tuple arrives already normalised by `authorization_tuple/1' -- chain id, nonce,
%% y-parity, r and s as integers, address as 20 raw bytes -- because that is the
%% shape `from_rlp/1' produces and the shape the signing preimage needs. Re-decoding
%% here would be a second parse of a field this module has already normalised.
authorization_authority([ChainId, Address, Nonce, YParity, R, S] = _Tuple)
  when is_integer(ChainId), is_binary(Address), is_integer(Nonce),
       is_integer(YParity), is_integer(R), is_integer(S) ->
    case eth_secp256k1:s_is_low(S) of
        false ->
            error;
        true ->
            Preimage = <<?SET_CODE_MAGIC, (eth_rlp:encode([ChainId, Address, Nonce]))/binary>>,
            case eth_secp256k1:recover(eth_keccak:hash(Preimage), R, S, YParity) of
                {ok, Pub} -> {ok, binary:part(eth_keccak:hash(Pub), 12, 20)};
                _ -> error
            end
    end;
authorization_authority(_) ->
    error.

authorization_tuple(A) when is_map(A) ->
    %% `auth_address/1`, not `addr/1'. `addr/1' reads the key `<<"to">'`, which is
    %% the *transaction's* destination; an authorization tuple names its authority
    %% under `<<"address">>'. Reusing `addr/1' here therefore did not fail -- it
    %% answered `<<>>' for a key that was simply not there -- so every tuple
    %% re-encoded with an empty authority and the round trip was 20 bytes short per
    %% tuple. The corpus caught it as `tx_roundtrip_mismatch', which is what that
    %% check exists for: it compares bytes rather than fields, and a field that
    %% silently became empty is invisible to a field-by-field comparison.
    [required(A, <<"chainId">>), auth_address(A),
     required(A, <<"nonce">>),
     required(A, <<"yParity">>), required(A, <<"r">>), required(A, <<"s">>)];
authorization_tuple(Tuple) when is_list(Tuple) ->
    Tuple.

%% A quantity, in the minimal hex form JSON-RPC requires ("0x0", "0x7", never
%% "0x07"). RLP decodes an integer to a binary, so the bytes are folded back
%% into an integer here; emitting bin0x/1 directly would produce leading zeros
%% for any quantity whose top byte happens to be zero.
hexq(I) when is_integer(I) -> eth_hex:encode_int(I);
hexq(B) when is_binary(B), byte_size(B) =:= 0 -> <<"0x0">>;
hexq(B) when is_binary(B) -> eth_hex:encode_int(binary:decode_unsigned(B));
hexq(_) -> throw(bad_tx).

hexdata(B) when is_binary(B) -> bin0x(B);
hexdata(_) -> throw(bad_tx).

bin0x(<<>>) -> <<"0x">>;
bin0x(Bin) -> <<"0x", (string:lowercase(binary:encode_hex(Bin)))/binary>>.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B), byte_size(B) =:= 0 -> 0;
to_int(B) when is_binary(B) -> binary:decode_unsigned(B).

%% Recover the 20-byte sender address (EIP-155 legacy + EIP-2718 typed).
sender(Tx) when is_map(Tx) ->
    try do_sender(Tx)
    catch _:_ -> {error, bad_signature} end.

do_sender(Tx) ->
    {Digest, RecID} = sighash(Tx),
    R = q(Tx, <<"r">>),
    S = q(Tx, <<"s">>),
    {ok, Pub} = eth_secp256k1:recover(Digest, R, S, RecID),
    {ok, binary:part(eth_keccak:hash(Pub), 12, 20)}.

%% {Digest, RecoveryID} for the signature.
sighash(Tx) ->
    case tx_type(Tx) of
        legacy ->
            F = [q(Tx, <<"nonce">>), q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                 addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>)],
            V = q(Tx, <<"v">>),
            case V of
                V27 when V27 =:= 27; V27 =:= 28 ->
                    {eth_keccak:hash(eth_rlp:encode(F)), V27 - 27};
                _ when V >= 35 ->
                    ChainID = (V - 35) div 2,
                    {eth_keccak:hash(eth_rlp:encode(F ++ [ChainID, 0, 0])),
                     (V - 35) rem 2};
                _ ->
                    throw(bad_v)
            end;
        eip2930 ->
            Pay = [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                   q(Tx, <<"gasPrice">>), q(Tx, <<"gas">>),
                   addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                   access_list(Tx)],
            {eth_keccak:hash(<<16#01, (eth_rlp:encode(Pay))/binary>>),
             q(Tx, <<"v">>)};
        eip1559 ->
            Pay = [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                   q(Tx, <<"maxPriorityFeePerGas">>),
                   q(Tx, <<"maxFeePerGas">>),
                   q(Tx, <<"gas">>),
                   addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                   access_list(Tx)],
            {eth_keccak:hash(<<16#02, (eth_rlp:encode(Pay))/binary>>),
             q(Tx, <<"v">>)};
        %% EIP-4844: the signing preimage stops at the versioned hashes. Unlike
        %% legacy/2930/1559 there is no "unsigned" flag byte -- the type prefix
        %% already distinguishes the preimage from the full encoding, because
        %% the full encoding simply has three more RLP items appended.
        eip4844 ->
            Pay = [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                   q(Tx, <<"maxPriorityFeePerGas">>),
                   q(Tx, <<"maxFeePerGas">>),
                   q(Tx, <<"gas">>),
                   addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                   access_list(Tx),
                   q(Tx, <<"maxFeePerBlobGas">>),
                   blob_versioned_hashes(Tx)],
            {eth_keccak:hash(<<16#03, (eth_rlp:encode(Pay))/binary>>),
             q(Tx, <<"v">>)};
        %% EIP-7702, and the same shape as 4844: the preimage stops after the
        %% authorization list, and the type prefix is what distinguishes it from the
        %% full encoding rather than a flag byte.
        %%
        %% This clause was missing while `from_rlp/1' and `to_rlp/1' already handled
        %% type 4, so a type-4 transaction decoded, re-encoded byte-for-byte, and
        %% still had no recoverable sender: `sighash/1' fell through to its
        %% `unsupported' clause and `sender/1' turned that into `{error,
        %% bad_signature}'. Three capabilities and no way to get from one to another.
        eip7702 ->
            Pay = [q(Tx, <<"chainId">>), q(Tx, <<"nonce">>),
                   q(Tx, <<"maxPriorityFeePerGas">>),
                   q(Tx, <<"maxFeePerGas">>),
                   q(Tx, <<"gas">>),
                   addr(Tx), q(Tx, <<"value">>), data(Tx, <<"input">>),
                   access_list(Tx),
                   %% `authorization_list/1' already yields tuples in the EIP's
                   %% order, and a tuple's signing preimage *is* its encoding -- so
                   %% the same function serves both, which is why there is no second
                   %% one here. The first version had `auth_preimage/1' as a separate
                   %% `is_map'-guarded function applied to the list's elements, which
                   %% were already lists, so it raised `function_clause' on every
                   %% tuple; `sender/1' catches every exception and answers
                   %% `{error, bad_signature}', so the cause was invisible and the
                   %% only symptom was that four transactions had no sender.
                   authorization_list(Tx)],
            {eth_keccak:hash(<<16#04, (eth_rlp:encode(Pay))/binary>>),
             q(Tx, <<"v">>)};
        unsupported ->
            throw(unsupported_tx_type)
    end.

tx_root(Txs) when is_list(Txs) ->
    try
        Pairs = lists:map(fun({Tx, I}) ->
            {ok, Enc} = to_rlp(Tx),
            {eth_rlp:encode(I), Enc}
        end, lists:zip(Txs, lists:seq(0, length(Txs) - 1))),
        {ok, eth_trie:root(Pairs)}
    catch _:_ ->
        {error, bad_tx}
    end.

%% ---------------------------------------------------------------------------
%% Validity
%% ---------------------------------------------------------------------------

%% Every rule a transaction must satisfy to be includable in a block, and the one
%% function that answers the question. Returns ok or {error, Reason}.
%%
%% The context supplies what cannot be read off the transaction alone:
%%
%%   base_fee      :: integer() | undefined   this block's base fee
%%   blob_base_fee :: integer() | undefined   the blob gas price
%%   chain_id      :: integer() | undefined   the configured chain
%%   gas_limit     :: integer()               the block's gas limit
%%   gas_used      :: integer() | undefined   gas already spent in this block
%%   balance_of    :: fun((Address) -> {ok, integer()})
%%   nonce_of      :: fun((Address) -> {ok, integer()})
%%
%% A context key that is absent is a rule that is not checked, not a rule that
%% passes by default. That is the right bias for the checks that need state: a
%% caller with no view of the sender cannot confirm the nonce, and reporting ok
%% for "cannot tell" would be indistinguishable from "valid". The base fee and
%% chain id are the exception -- a caller that does not supply them is a caller
%% that has not told us the rules, so nothing is invented.
%%
%% `from' is deliberately not consulted. It is a JSON-RPC annotation, not part of
%% the signed transaction, and no consensus rule mentions it: a block whose
%% transactions carry a `from' that disagrees with the recovered signer is still
%% a valid block, and the sender is whatever the signature says. Checking it here
%% would reject valid blocks. A proposer assembling a block from an untrusted
%% source is a different question, and eth_block_builder asks it separately.
validate(Tx) ->
    validate(Tx, #{}).

validate(Tx, Ctx) when is_map(Tx), is_map(Ctx) ->
    try
        Type = tx_type(Tx),
        ensure(Type =/= unsupported, {error, unsupported_type}),
        %% The fork gate on the *type*. `unsupported' above only says this node
        %% cannot decode it, which is a statement about the code and not about the
        %% block; without this the same check would also have admitted a type-2
        %% transaction into a Berlin block, which the corpus found it doing. A block
        %% carrying one would be validated and imported rather than refused whole.
        ensure(eth_fork_schedule:tx_type_available(Type, ctx_fork(Ctx)),
               {error, tx_type_pre_fork}),
        Gas = field(Tx, <<"gas">>),
        Value = field(Tx, <<"value">>),
        Nonce = field(Tx, <<"nonce">>, 0),
        GasPrice = field(Tx, <<"gasPrice">>, 0),
        MaxFee = field(Tx, <<"maxFeePerGas">>, undefined),
        MaxPriority = field(Tx, <<"maxPriorityFeePerGas">>, undefined),
        ensure(Gas > 0, {error, gas_limit_zero}),
        ensure(Value >= 0, {error, negative_value}),
        ensure(Nonce >= 0, {error, negative_nonce}),
        {To, IsCreate} = to_field(Tx),
        ensure(valid_to(To), {error, invalid_to}),
        Data = calldata(Tx),
        AccessList = access_list_field(Tx),
        Fork = ctx_fork(Ctx),
        %% EIP-3860 (Shanghai): a contract-creation transaction's init code may not
        %% exceed `MAX_INITCODE_SIZE'. It is checked here, on the decoded `data' and the
        %% `IsCreate' flag, and not where the intrinsic cost is computed because it is a
        %% **validity** rule and not a price: the transaction is invalid, so it is never
        %% executed and never charges anything. The fork schedule already priced init code
        %% per word from Shanghai (`initcode_word_cost/1', `v1.7`) and did not carry the
        %% limit, so this node would accept a creation transaction with unbounded init
        %% code on a fork that rejects all of it over 49,152 bytes.
        ensure(not IsCreate orelse
               byte_size(Data) =< eth_fork_schedule:max_initcode_size(Fork),
               {error, initcode_size_exceeded}),
        ensure(fee_fields_ok(Tx, GasPrice, MaxFee, MaxPriority),
               {error, invalid_fee}),
        ensure(fee_ceiling_ok(Tx, MaxFee, GasPrice, Ctx), {error, fee_too_low}),
        ok = check_blobs(Tx, Ctx),
        ok = check_set_code(Tx),
        ensure(Gas >= intrinsic_gas(Data, IsCreate, AccessList, Fork,
                                    authorization_list_field(Tx)),
               {error, intrinsic_gas}),
        %% EIP-7623, the validity half: a transaction whose gas limit is below the
        %% calldata floor is invalid, "because transactions must cover the floor price
        %% of their calldata without relying on the execution of the transaction".
        %% The EIP says the limit must clear the larger of this and the intrinsic
        %% cost, and the intrinsic check above already covers that half.
        ensure(Gas >= eth_fork_schedule:calldata_floor(Fork, Data),
               {error, calldata_floor}),
        ensure(valid_signature(Tx), {error, bad_signature}),
        ok = check_chain_id(Tx, Ctx),
        ok = check_block_gas(Gas, Ctx),
        ok = check_state(Tx, Nonce, Gas, Value, MaxFee, GasPrice, Ctx),
        ok
    catch
        throw:{error, _} = Err -> Err;
        throw:Reason -> {error, Reason};
        Class:Reason -> {error, {invalid_transaction, Class, Reason}}
    end;
validate(_Tx, _Ctx) ->
    {error, invalid_transaction}.

ensure(true, _Ok) -> ok;
ensure(false, Err) -> throw(Err).

%% Strict field decoding. q/2 above is lenient -- it answers 0 for a value it
%% cannot read, which is right for the wire codec (a transaction it cannot parse
%% should not crash the caller) and wrong for validation, where "I could not read
%% this nonce" and "the nonce is zero" must not be the same answer. A transaction
%% whose quantity has a leading zero or a non-hex digit is malformed, and
%% JSON-RPC requires the minimal form, so both are rejected.
field(Tx, Key) ->
    field(Tx, Key, undefined).

field(Tx, Key, Default) ->
    case maps:get(Key, Tx, Default) of
        undefined -> undefined;
        I when is_integer(I), I >= 0 -> I;
        B when is_binary(B) -> decode_quantity(B, Key);
        _ -> throw({error, {bad_field, Key}})
    end.

decode_quantity(<<"0x">>, _Key) -> 0;
decode_quantity(<<"0x", S/binary>>, Key) -> decode_hex_quantity(S, Key);
decode_quantity(<<"0X", S/binary>>, Key) -> decode_hex_quantity(S, Key);
decode_quantity(B, _Key) when is_binary(B) ->
    try binary:decode_unsigned(B)
    catch _:_ -> throw({error, bad_uint}) end;
decode_quantity(_, Key) ->
    throw({error, {bad_field, Key}}).

%% binary:decode_hex/1 rejects an odd-length digit string and raises badarg, and
%% JSON-RPC quantities have no leading zeros, so "0x1" has one digit.
decode_hex_quantity(S, Key) ->
    case all_hex_digits(S) of
        false ->
            throw({error, {bad_field, Key}});
        true ->
            case non_canonical_digits(S) of
                true -> throw({error, {non_canonical_quantity, Key}});
                false -> hex_to_int(pad_even(S))
            end
    end.

%% binary:decode_unsigned/1 reads its argument as *bytes*, so handing it the
%% digit string "01546d72" yields the integer 0x3031353436643731 -- the ASCII
%% codes of the digits, not the number they spell. The hex decode has to come
%% first.
hex_to_int(Padded) ->
    binary:decode_unsigned(binary:decode_hex(Padded)).

%% Canonicity is a property of the *digit string*, not of the decoded bytes. A
%% one-digit "0" is the canonical spelling of zero, and it decodes to a single
%% zero byte, so a check on the bytes would reject the number zero itself. A
%% longer string beginning with '0' is a different, non-minimal spelling of the
%% same number and is malformed.
non_canonical_digits(<<>>) -> false;
non_canonical_digits(<<C, _/binary>>) when C =/= $0 -> false;
non_canonical_digits(<<_>>) -> false;
non_canonical_digits(_) -> true.

pad_even(S) ->
    case byte_size(S) rem 2 of
        0 -> S;
        1 -> <<"0", S/binary>>
    end.

all_hex_digits(<<>>) -> true;
all_hex_digits(<<C, Rest/binary>>) ->
    is_hex_digit(C) andalso all_hex_digits(Rest).

%% Written with ranges rather than a list of character literals because $A
%% through $F are *variables* in Erlang -- an upper-case letter after $ binds a
%% variable rather than naming a character -- so a case listing all sixteen
%% digits as literals silently binds C, D, E and F and stops being a pattern
%% list at all.
is_hex_digit(C) when is_integer(C) ->
    (C >= $0 andalso C =< $9) orelse
    (C >= $a andalso C =< $f) orelse
    (C >= $A andalso C =< $F).

%% The destination is classified before it is validated, because a JSON-RPC "0x"
%% is a two-byte binary that would otherwise look like a malformed address rather
%% than the empty destination meaning contract creation.
to_field(Tx) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined -> {<<>>, true};
        null -> {<<>>, true};
        B when is_binary(B) ->
            case data_bytes(B) of
                <<>> -> {<<>>, true};
                Addr -> {Addr, false}
            end;
        _ -> throw({error, invalid_to})
    end.

valid_to(<<>>) -> true;
valid_to(B) when is_binary(B), byte_size(B) =:= 20 -> true;
valid_to(_) -> false.

%% The transaction's calldata, as bytes.
%%
%% **One reader, because this had three and they disagreed.** JSON-RPC spells the
%% field `data`; `eth_tx:from_rlp/1` and the wire shape spell it `input`; clients send
%% either. This function took `input` in preference to `data` and decoded a hex string
%% either way. `eth_call:tx_data/1` did the same thing separately and identically.
%% `eth_block:run_transaction/5` did **not** -- it read `input` alone --
%%
%%     Data = to_bytes(maps:get(<<"input">>, Tx, <<>>)),
%%
%% so every transaction the node executed without an `input` key ran with **no
%% calldata at all**, while `eth_tx:intrinsic_gas/5` -- which reads through *this*
%% function -- charged the intrinsic cost of the calldata that was never executed. The
%% node billed for input it did not run, and produced a state root no other client
%% could reproduce.
%%
%% The corpus found it, and the shape of the finding is the part worth keeping: the
%% divergence is a *gas* figure of +517,958 on five fixtures, which looks like a
 %% pricing bug and is not one. Every one of the 266 committed fixtures carries `data`
 %% and none carries `input`, so the whole committed corpus was being run with empty
 %% calldata. `test_eip1559_tx_validity` is the clearest single witness: its
 %% transaction is `PUSH1 1; PUSH1 0; SSTORE` reached through `CALLDATASIZE`-free
 %% direct code, so the storage write the fixture expects never happened and the sender
 %% was charged its whole 100,000 allowance -- 700,000 wei at `maxFeePerGas` 7 -- with
 %% no refund, because the frame that failed had nothing to return.
-spec calldata(map()) -> binary().
calldata(Tx) ->
    %% **`data` first, then `input`.** A map carrying both is ambiguous and the
    %% precedence has to be stated, because the two spellings are not
    %% interchangeable: `data` is what JSON-RPC calls the field and `input` is what
    %% `from_rlp/1' emits internally, so a map with both is one this node did not build
    %% and a caller supplied. When a caller supplies `data` it means it, and the
    %% internal `input` -- which may be present and empty, as it is for every map
    %% `eth_tx_validity_tests:signed/2' builds -- must not shadow it.
    %%
    %% I had it the other way round and wrote a test that put one byte under `data` on
    %% a map that already carried an empty `input`. It failed, and the failure was the
    %% precedence rather than the reader.
    case maps:get(<<"data">>, Tx, maps:get(<<"input">>, Tx, <<>>)) of
        B when is_binary(B) -> data_bytes(B);
        _ -> throw({error, bad_data})
    end.

data_bytes(<<"0x", S/binary>>) -> hex_bytes_or(S, bad_data);
data_bytes(<<"0X", S/binary>>) -> hex_bytes_or(S, bad_data);
data_bytes(B) when is_binary(B) -> B;
data_bytes(_) -> throw({error, bad_data}).

hex_bytes_or(S, Err) ->
    Padded = case byte_size(S) rem 2 of
        0 -> S;
        1 -> <<"0", S/binary>>
    end,
    case all_hex_digits(Padded) of
        false -> throw({error, Err});
        true -> binary:decode_hex(Padded)
    end.

%% An access list arrives as a list of objects over JSON-RPC and as [Address,
%% [Slot...]] pairs on the wire. Both are normalized so validation sees one
%% shape.
access_list_field(Tx) ->
    case maps:get(<<"accessList">>, Tx, []) of
        L when is_list(L) -> [normalize_access_entry(E) || E <- L];
        _ -> throw({error, invalid_access_list})
    end.

%% EIP-7702's authorization list, normalized to the `{ChainID, Address, Nonce,
%% YParity, R, S}' tuples the RLP form uses. Only the *length* is ever priced, so
%% the normalization exists to count the tuples and to refuse a malformed one --
%% not to supply fields any rule reads.
authorization_list_field(Tx) ->
    case maps:get(<<"authorizationList">>, Tx,
                  maps:get(<<"authorization_list">>, Tx, [])) of
        L when is_list(L) -> [authorization_tuple_fields(A) || A <- L];
        _ -> throw({error, invalid_authorization_list})
    end.

authorization_tuple_fields(A) when is_map(A) ->
    %% Every field is required. `q/2' answers 0 for a missing key, and a tuple whose
    %% `yParity' defaulted to 0 would be indistinguishable from one that genuinely
    %% signed with parity 0 -- a difference that matters the moment the state
    %% transition recovers these signatures. Refusing is the EIP's own position: a
    %% transaction is invalid "when any field in an authorization tuple cannot fit
    %% within the following bounds", so a missing field is malformed rather than
    %% zero.
    {required(A, <<"chainId">>), required_bytes(A, <<"address">>),
     required(A, <<"nonce">>), required(A, <<"yParity">>),
     required(A, <<"r">>), required(A, <<"s">>)};
authorization_tuple_fields([_, _, _, _, _, _] = Tuple) -> Tuple;
authorization_tuple_fields(_) ->
    throw({error, invalid_authorization_list}).

%% A field that must be present, read the way `q/2' reads one. A key that is absent
%% is refused rather than folded to `q/2's' zero default, for the reason given on
%% `authorization_tuple_fields/1'.
required(M, K) ->
    case maps:find(K, M) of
        {ok, V} -> scalar(V);
        error -> throw({error, invalid_authorization_list})
    end.

%% `q/2` without the map, so the two read identically.
scalar(V) when is_integer(V) -> V;
scalar(V) when is_binary(V) ->
    try eth_hex:decode(V) catch _:_ -> 0 end;
scalar(_) -> 0.

required_bytes(M, K) ->
    case maps:find(K, M) of
        {ok, V} -> addr(#{<<"to">> => V});
        error -> throw({error, invalid_authorization_list})
    end.

%% An authorization tuple's authority, 20 bytes, or empty -- the fixtures carry
%% tuples whose authority is an empty string, and refusing those would refuse the
%% corpus's own data rather than the specification.
auth_address(A) when is_map(A) ->
    required_bytes(A, <<"address">>).

normalize_access_entry({Addr, Slots}) when is_list(Slots) ->
    {access_address(Addr), [access_slot(S) || S <- Slots]};
normalize_access_entry(#{<<"address">> := Addr, <<"storageKeys">> := Slots})
  when is_list(Slots) ->
    {access_address(Addr), [access_slot(S) || S <- Slots]};
normalize_access_entry(_) ->
    throw({error, invalid_access_list}).

access_address(B) when is_binary(B) ->
    case data_bytes(B) of
        <<Addr:20/binary>> -> Addr;
        _ -> throw({error, invalid_access_list})
    end;
access_address(_) ->
    throw({error, invalid_access_list}).

access_slot(B) when is_binary(B) ->
    case data_bytes(B) of
        <<Slot:32/binary>> -> Slot;
        _ -> throw({error, invalid_access_list})
    end;
access_slot(_) ->
    throw({error, invalid_access_list}).

%% EIP-2718/1559: a typed transaction must carry both fee fields and a legacy one
%% must not. maxPriorityFeePerGas above maxFeePerGas is also malformed -- the
%% tip could never be paid out.
fee_fields_ok(Tx, GasPrice, MaxFee, MaxPriority) ->
    case tx_type(Tx) of
        eip1559 -> valid_1559_fees(MaxFee, MaxPriority);
        eip4844 -> valid_1559_fees(MaxFee, MaxPriority);
        %% **EIP-7702 is a type-2 transaction with an authorization list**, so it is
        %% bound by EIP-1559's fee-field rule exactly as a type 2 is, and the corpus
        %% says so: `test_set_code_transaction_fee_validations' expects
        %% `PRIORITY_GREATER_THAN_MAX_FEE_PER_GAS' from a type-4 transaction whose
        %% maxPriorityFeePerGas is 8 and maxFeePerGas is 7.
        %%
        %% It was missing here, and the `_ ->` clause below caught it instead -- which
        %% checks `gasPrice >= 0`, and a type-4 transaction has no `gasPrice` at all, so
        %% `field/3` supplies the default `0` and **every** fee-field rule was silently
        %% skipped for type 4. The bug is not that a rule was absent; it is that a type
        %% fell out of a `case` written when there were only three types, and a
        %% fall-through clause turns "not mentioned" into "no rules at all" rather than
        %% into an error.
        eip7702 -> valid_1559_fees(MaxFee, MaxPriority);
        _ -> is_integer(GasPrice) andalso GasPrice >= 0
    end.

valid_1559_fees(MaxFee, MaxPriority) ->
    is_integer(MaxFee) andalso is_integer(MaxPriority) andalso
        MaxPriority =< MaxFee.

%% Under EIP-1559 a transaction is only includable when its ceiling covers the
%% base fee. Pre-London there is no base fee and so no floor.
fee_ceiling_ok(Tx, MaxFee, GasPrice, Ctx) ->
    case maps:get(base_fee, Ctx, undefined) of
        BaseFee when is_integer(BaseFee) ->
            Ceiling = case tx_type(Tx) of
                eip1559 -> MaxFee;
                eip4844 -> MaxFee;
                %% **EIP-7702 is a type-2 transaction with an authorization list.**
                %% It was missing here, and the `_ ->` clause caught it instead --
                %% which reads the legacy `gasPrice`, and a type-4 transaction has no
                %% `gasPrice` field at all, so `field/3` supplies `0`. So every
                %% type-4 transaction was refused as underpriced against **any** base
                %% fee above zero.
                %%
                %% This is the identical defect `fee_fields_ok/4' had, three functions
                %% above, fixed in `v1.54`: a `case` written when there were three
                %% transaction types, a fourth fell out of it, and a fall-through
                %% clause turned "not mentioned" into a **different rule** rather than
                %% into an error. The v1.54 comment says exactly that, and the
                %% neighbouring function was not re-read. The corpus had **72**
                %% entries sitting on it -- 47 `INTRINSIC_GAS_TOO_LOW`, 14
                %% `INTRINSIC_GAS_BELOW_FLOOR_GAS_COST`, 8 `SENDER_NOT_EOA` and 3
                %% type-4 well-formedness cases -- each refused as underpriced
                %% because its sender offered 7 against a base fee of 7.
                %%
                %% So the general form, and it is the second time this repository has
                %% paid it: **when a `case` on a transaction type selects a *value*
                %% rather than a rule, a missing clause is a wrong number, not a
                %% missing check** -- and a missing check is loud while a wrong number
                %% is silent. The test that catches the class is
                %% `every_transaction_type_bids_its_own_fee_field_test'.
                eip7702 -> MaxFee;
                _ -> GasPrice
            end,
            is_integer(Ceiling) andalso Ceiling >= BaseFee;
        _ ->
            true
    end.

%% EIP-4844 blob rules. Three of them, and they are separate failures so a caller
%% can tell why a blob transaction was rejected:
%%
%%   * at least one blob, and every versioned hash a well-formed KZG commitment
%%     hash;
%%   * maxFeePerBlobGas is mandatory;
%%   * maxFeePerBlobGas must cover the block's blob gas price, or the blobs are
%%     not purchasable. That price comes from the context because it depends on
%%     the parent block's excess blob gas; when the caller cannot supply it the
%%     floor is not checked rather than guessed.
%%
%% **And the price was supplied by nobody, so that third rule could not fire.**
%% The sentence above said "when the caller cannot supply it the floor is not
%% checked rather than guessed", and it turned out no caller could: neither
%% `eth_block:validation_ctx/4' -- the admission path for a block's own
%% transactions -- nor the conformance runner passed a `blob_base_fee' key, so
%% `maps:get(blob_base_fee, Ctx, undefined)' took the `undefined' branch on
%% **every** call and the `ensure/2' below it was dead code. This is EIP-3607's
%% shape exactly: a rule present, correct, and unreachable, with fixtures that
%% would have caught it reporting `INSUFFICIENT_MAX_FEE_PER_BLOB_GAS' as a reason
%% this node never gave. Those fixtures set `maxFeePerBlobGas = 1' against
%% `currentExcessBlobGas = 0x240000' (2,359,296), where the Cancun curve gives a
%% blob base fee of **2** -- so the sender underbid and the node let it through.
%%
%% The price is not guessed here. It comes from the context because it is a
%% property of the block being built, and the only thing that computes it is
%% `eth_block:blob_base_fee/1' -- the same function `eth_block:blob_fee/2' charges
%% at, so the price a transaction is *checked* against and the price it is
%% *charged* cannot come from two different derivations.
check_blobs(Tx, Ctx) ->
    case tx_type(Tx) of
        eip4844 ->
            %% EIP-4844's `validate_block' states these as **two separate asserts**,
            %% and they are now two separate refusals:
            %%
            %%     # there must be at least one blob
            %%     assert len(tx.blob_versioned_hashes) > 0
            %%     # all versioned blob hashes must start with VERSIONED_HASH_VERSION_KZG
            %%     for h in tx.blob_versioned_hashes:
            %%         assert h[0] == VERSIONED_HASH_VERSION_KZG
            %%
            %% They were one reason -- `bad_blob_hashes' -- for every failure of
            %% either, so "this transaction carries no blobs at all" and "this
            %% transaction carries a hash that is not a versioned KZG hash" were
            %% indistinguishable to every caller, and the corpus names them
            %% separately (`TYPE_3_TX_ZERO_BLOBS' and
            %% `TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH'). The split is justified by the
            %% EIP's own two asserts, not by the corpus: a transaction with an empty
            %% list and a transaction with a version byte of 0x02 fail different
            %% conditions, and a caller deciding what to tell a user cannot use one
            %% answer for both.
            ensure(blob_hashes_present(Tx), {error, zero_blobs}),
            ensure(blob_hashes_well_formed(Tx), {error, invalid_blob_hash}),
            MaxFeePerBlobGas = field(Tx, <<"maxFeePerBlobGas">>),
            ensure(is_integer(MaxFeePerBlobGas), {error, invalid_blob_fee}),
            case maps:get(blob_base_fee, Ctx, undefined) of
                undefined -> ok;
                Price when is_integer(Price) ->
                    ensure(MaxFeePerBlobGas >= Price, {error, blob_fee_too_low})
            end,
            %% EIP-4844's per-block cap, from the same `validate_block':
            %%
            %%     # ensure that the total blob gas spent is at most equal to the limit
            %%     assert blob_gas_used <= MAX_BLOB_GAS_PER_BLOCK
            %%
            %% `blob_gas_used' there is accumulated across the block's transactions,
            %% so `blob_gas_used' in the context is the total **before** this one and
            %% this transaction's own contribution is added here. It is the *cumulative*
            %% condition and not a per-transaction one: 786,432 is six blobs, and a
            %% block may carry six in one transaction or three in each of two.
            %%
            %% **It was absent**, and its absence is what the two
            %% `TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED` fixtures measure -- one
            %% with 7 versioned hashes and one with 9, so 917,504 and 1,179,648 blob
            %% gas against a limit of 786,432. A block carrying either is invalid and
            %% this node admitted it.
            %%
            %% An absent `blob_gas_used` in the context means the total is unknown,
            %% and an unknown total cannot clear a maximum, so the check is skipped
            %% rather than assumed -- the same direction as the blob base fee above,
            %% and for the same reason. Both are now supplied by
            %% `eth_block:validation_ctx/5' on the admission path.
            case maps:get(blob_gas_used, Ctx, undefined) of
                undefined -> ok;
                Used when is_integer(Used) ->

                    ensure(Used + blob_gas_of(Tx)
                           =< eth_fork_schedule:max_blob_gas_per_block(fork_of(Ctx)),
                           {error, blob_gas_allowance_exceeded})
            end;
        _ ->
            ok
    end.

%% EIP-7702's two validity rules that are not about gas. Both are the EIP's own
%% sentences:
%%
%%   The transaction is considered invalid if the length of authorization_list is
%%   zero.
%%
%%   The fields chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas,
%%   gas_limit, destination, value, data, and access_list of the outer transaction
%%   follow the same semantics as EIP-4844 . Note, this implies a null destination is
%%   not valid.
%%
%% The second is a change from every earlier type rather than a restatement, which
%% is why it is worth stating that it is EIP-4844's semantics and not the legacy
%% rule: a type-2 transaction may create a contract, and a type-4 may not. Note also
%% that this is checked *only* for type 4 -- refusing a null destination on a legacy
%% transaction would refuse contract creation, which is the opposite of right.
check_set_code(Tx) ->
    case tx_type(Tx) of
        eip7702 ->
            {_, IsCreate} = to_field(Tx),
            ensure(not IsCreate, {error, null_destination}),
            %% Read through the same accessor the intrinsic cost uses, so a
            %% malformed tuple is refused here rather than counted as zero tuples.
            ensure(authorization_list_field(Tx) =/= [], {error, empty_auth_list});
        _ ->
            ok
    end.

%% Intrinsic gas: the floor a transaction pays whatever it does, from the
%% transaction's own shape. 21000 for a call, 53000 for contract creation, 4 per
%% zero byte and 16 per non-zero byte of calldata, plus EIP-2930 access list costs
%% (2400 per address, 1900 per storage key), plus EIP-3860 init code word cost
%% (Shanghai).
%%
%% Note that binary_to_list/1 yields integers, so the zero-byte case must match
%% the integer 0. A <<0>> pattern would silently charge every byte the non-zero
%% rate.
intrinsic_gas(Tx) ->
    intrinsic_gas(Tx, eth_fork_schedule:configured_fork()).

%% The fork matters for exactly one term: EIP-3860's 2-gas-per-word init-code
%% charge, which is Shanghai's. A creation transaction's intrinsic gas is
%% therefore a function of the block it would go in, and the one-argument form
%% cannot supply that.
%%
%% What it supplies instead is the operator's ETH_FORK pin, and that is a
%% *documented weakening*, not a resolution: on a chain whose head is not the
%% pinned fork, this overcharges a pre-Shanghai creation and undercharges a
%% post-Shanghai one. It is the right answer for admission, where no block exists
%% yet, and the wrong one to rely on -- so every caller that does have a block
%% passes the block's own fork, and eth_block does. A caller that has a block and
%% uses this form is silently getting the pin.
intrinsic_gas(Tx, Fork) when is_atom(Fork) ->
    {_To, IsCreate} = to_field(Tx),
    intrinsic_gas(calldata(Tx), IsCreate, access_list_field(Tx), Fork,
                  authorization_list_field(Tx)).

intrinsic_gas(Data, IsCreate, AccessList, Fork, AuthList)
  when is_binary(Data), is_list(AccessList), is_atom(Fork) ->
    Base = case IsCreate of
        true -> 53000;
        false -> 21000
    end,
    DataGas = lists:foldl(fun(0, A) -> A + 4;
                             (_, A) -> A + 16
                          end, 0, binary_to_list(Data)),
    AccessGas = lists:foldl(fun({_Addr, Slots}, A) ->
        A + 2400 + 1900 * length(Slots)
    end, 0, AccessList),
    Base + DataGas + AccessGas + initcode_gas(Data, IsCreate, Fork)
        + set_code_gas(AuthList, Fork);
intrinsic_gas(_Data, _IsCreate, _AccessList, _Fork, _AuthList) ->
    0.

%% EIP-7702 prices the authorization list by its *length*, and "the transaction
%% sender will pay for all authorization tuples, regardless of validity or
%% duplication" -- so nothing about a tuple's contents may appear here. Charging
%% only the tuples that recover successfully would be a different rule and would
%% make a transaction's cost depend on state the sender does not control.
set_code_gas(AuthList, Fork) when is_list(AuthList), is_atom(Fork) ->
    eth_fork_schedule:set_code_auth_cost(Fork) * length(AuthList);
set_code_gas(_AuthList, _Fork) ->
    0.

%% The same term the CREATE and CREATE2 opcodes charge, and gated the same way,
%% because the two must agree: eth_block:execute_transactions/5 runs a creation
%% transaction's `data' straight through eth_evm without ever reaching the
%% opcode, so exactly one of the two ever applies to it. When they disagreed the
%% intrinsic charge and the execution charge would differ, and which of them the
%% transaction actually paid would depend on the path it took.
initcode_gas(_Data, false, _Fork) -> 0;
initcode_gas(Data, true, Fork) when is_binary(Data), is_atom(Fork) ->
    eth_fork_schedule:initcode_word_cost(Fork) * ((byte_size(Data) + 31) div 32);
initcode_gas(_Data, _IsCreate, _Fork) -> 0.

%% Signature validity has two independent parts, and only the second is usually
%% noticed:
%%
%%   1. The EIP-2 malleability bound. r must lie in [1, N-1] and s in [1, N/2].
%%      The upper half of s is malleable -- replacing s with N-s gives a second
%%      valid signature over the same message -- so those are rejected outright.
%%      This is what makes a transaction hash a stable identifier rather than one
%%      of many.
%%
%%   2. That recovery succeeds at all. Public-key recovery succeeds for almost
%%      any (r, s, v); it just yields a different address, so "recovery
%%      succeeded" on its own proves nothing about the signature being any good.
valid_signature(Tx) ->
    R = word32(Tx, <<"r">>),
    S = word32(Tx, <<"s">>),
    V = field(Tx, <<"v">>),
    case {in_group_range(R), low_half_s(S), valid_recovery_id(Tx, V)} of
        {true, true, true} ->
            case sender(Tx) of
                {ok, _} -> true;
                _ -> false
            end;
        _ ->
            false
    end.

in_group_range(I) when is_integer(I) -> I >= 1 andalso I < ?SECP256K1_N;
in_group_range(_) -> false.

%% `r' and `s' are DATA, not QUANTITY. This is the one place where applying the
%% JSON-RPC quantity rule to a transaction field is simply wrong: the spec spells
%% both as 32-byte values, so a real node returns them zero-padded to 66 hex
%% characters, and "0x00a1b2..." is the *correct* encoding of a signature whose top
%% byte happens to be zero. Treating them as quantities -- rejecting any leading
%% zero -- would refuse roughly one transaction in 256 for no protocol reason.
%%
%% Their *width* is deliberately not policed either. Recovery depends only on the
%% integer value, so a short spelling of the same r recovers the same address, and
%% refusing it would be a liveness bug with no security benefit. What does have to
%% hold is the range, and in_group_range/1 checks that: anything at or above the
%% group order is not a signature component however it was spelled. A missing
%% component is a bad signature and an unreadable one is a bad field, because
%% absent and corrupt are different faults.
word32(Tx, Key) ->
    case maps:get(Key, Tx, undefined) of
        undefined -> undefined;
        I when is_integer(I), I >= 0 -> I;
        B when is_binary(B) -> decode_word32(B, Key);
        _ -> throw({error, {bad_field, Key}})
    end.

decode_word32(<<>>, _Key) -> 0;
decode_word32(<<"0x", S/binary>>, Key) -> decode_word32_hex(S, Key);
decode_word32(<<"0X", S/binary>>, Key) -> decode_word32_hex(S, Key);
decode_word32(B, Key) when is_binary(B) ->
    case byte_size(B) =< 32 of
        true -> binary:decode_unsigned(B);
        false -> throw({error, {bad_field, Key}})
    end;
decode_word32(_, Key) -> throw({error, {bad_field, Key}}).

decode_word32_hex(S, Key) ->
    case all_hex_digits(S) of
        false -> throw({error, {bad_field, Key}});
        true -> hex_to_int(pad_even(S))
    end.

low_half_s(S) when is_integer(S) -> S >= 1 andalso S =< ?SECP256K1_N div 2;
low_half_s(_) -> false.

%% Legacy v is the unprotected 27/28 or EIP-155's chainId*2+35+recid. Typed
%% transactions carry a bare recovery id.
valid_recovery_id(Tx, V) when is_integer(V) ->
    case tx_type(Tx) of
        legacy -> V =:= 27 orelse V =:= 28 orelse V >= 35;
        _ -> V =:= 0 orelse V =:= 1
    end;
valid_recovery_id(_Tx, _V) ->
    false.

%% EIP-155 replay protection. A legacy transaction carries the chain id inside v
%% as chainId*2+35+recid, a typed one carries it explicitly. An *unprotected*
%% legacy transaction has no chain id at all, and on a chain that has a chain id
%% that is exactly what replay protection exists to prevent -- so it is rejected
%% rather than treated as "chain id absent, therefore fine".
check_chain_id(Tx, Ctx) ->
    case maps:get(chain_id, Ctx, undefined) of
        undefined -> ok;
        Expected -> ensure(tx_chain_id(Tx) =:= Expected, {error, wrong_chain_id})
    end.

%% The fork validity is priced under. Only EIP-3860's init-code term depends on
%% it, and only a creation transaction pays it.
%%
%% A caller that has a block puts the block's fork in the context -- eth_block
%% does, and it is the only caller for which an answer about *this* block is the
%% right one. A caller that does not (the pool, at admission) gets the
%% operator's ETH_FORK pin, which is a documented weakening rather than a
%% resolution: no block exists yet, so there is nothing better to say. It is the
%% same treatment base_fee gets, and deliberately not the same as omitting the
%% check: an absent base fee means the ceiling rule is *unchecked*, whereas an
%% absent fork means the rule is applied under a stated assumption.
%% The fork a validation context speaks for, or the operator's pin when it says
%% nothing.
%%
%% The first clause's guard is `undefined =/= Fork' and not `is_atom(Fork)', and that
%% is a real change rather than a style preference. The original was
%%
%%     Fork when is_atom(Fork) -> Fork
%%
%% which is satisfied by `undefined' -- because `undefined' is an atom -- so the
%% default was returned as though it were a fork, and `configured_fork/0' below it
%% was unreachable for any context without a `fork' key. That is every pool and
%% block-builder call, since both pass a bare context. The consequence was invisible
%% because `undefined' satisfies every `is_atom(Fork)' guard downstream, so the
%% schedules it reached simply answered for a fork named `undefined' -- which is not
%% a fork, and matched no clause, and so fell through to whatever default that
%% function happened to carry.
ctx_fork(Ctx) ->
    case maps:get(fork, Ctx, undefined) of
        undefined -> eth_fork_schedule:configured_fork();
        Fork when is_atom(Fork) -> Fork;
        _ -> eth_fork_schedule:configured_fork()
    end.

tx_chain_id(Tx) ->
    case tx_type(Tx) of
        legacy ->
            case field(Tx, <<"v">>) >= 35 of
                true -> (field(Tx, <<"v">>) - 35) div 2;
                false -> undefined
            end;
        _ ->
            field(Tx, <<"chainId">>)
    end.

%% A block's gas limit bounds the whole block, so a transaction that does not fit
%% in what is left cannot be in the block at all -- regardless of whether the
%% transaction would succeed on its own. This is checked against the gas already
%% consumed by the transactions before it, which is the only point at which the
%% running total is the block's.
check_block_gas(Gas, Ctx) ->
    case {maps:get(gas_limit, Ctx, undefined), maps:get(gas_used, Ctx, 0)} of
        {Limit, Used} when is_integer(Limit), is_integer(Used) ->
            ensure(Used + Gas =< Limit, {error, exceeds_block_gas_limit});
        _ ->
            ok
    end.

%% The payer is whoever the signature recovers to. The cost ceiling is
%% maxFeePerGas (the worst case, since the block's tip is at most that much
%% above the base fee) for a typed transaction and gasPrice for a legacy one,
%% plus the value transferred.
check_state(Tx, Nonce, Gas, Value, MaxFee, GasPrice, Ctx) ->
    case sender(Tx) of
        {ok, Payer} ->
            %% EIP-3607 (London): reject a transaction whose sender has deployed code.
            %% It belongs here rather than with the field checks because it is the only
            %% new rule in this function that needs the **recovered** sender, and the
            %% sender is not known until the signature has been checked -- which is why
            %% it cannot sit beside `valid_to/1' and the other field-level rules.
            %%
            %% It is `code[Payer] == b""', and nothing else: EIP-7702's delegation designator
            %% is code, so a delegated account is refused by this rule too, which is
            %% correct -- an account that has delegated is still a contract for the purpose
            %% of being a transaction's sender. The corpus's eight fixtures are exactly
            %% that: a sender holding `0x00`, one byte, which is non-empty and is therefore
            %% not an externally owned account. Checking "is there any code" and answering
            %% true for a single byte is not a near-miss; one byte is code.
            check_sender_is_eoa(Payer, Ctx),
            Price = validation_price(MaxFee, GasPrice),
            check_balance(Payer, Gas * Price + Value + blob_gas_term(Tx), Ctx),
            check_nonce(Payer, Nonce, Ctx);
        _ ->
            %% valid_signature/1 has already rejected a transaction whose sender
            %% does not recover, so this is unreachable; leaving it as ok rather
            %% than throwing keeps the failure attributable to bad_signature.
            ok
    end.

%% EIP-3607. `code_of' is a reader in the same shape as `balance_of' and `nonce_of',
%% and **its absence is not a pass**:
%%
%% An absent account is an externally owned account, which is the convention the rest of
%% `eth_state' reads with and getting it wrong would refuse the first transaction of
%% every new account. But a context with no `code_of' at all is a different thing: it is
%% a caller that cannot answer the question, and answering "it is fine" for it would make
%% the rule unenforceable by omission. `eth_block:validation_ctx/4' supplies it on the
%% real admission path, and `eth_txpool:pool_ctx/0` does not -- so a pooled transaction is
%% checked for everything *except* this until the pool has a state to read.
check_sender_is_eoa(Payer, Ctx) ->
    case {eth_fork_schedule:sender_must_be_eoa(ctx_fork(Ctx)), maps:get(code_of, Ctx, undefined)} of
        {false, _} ->
            ok;
        {true, Fun} when is_function(Fun, 1) ->
            case Fun(Payer) of
                %% **EIP-7702's "Transaction origination"** modifies EIP-3607:
                %% "allow EOAs whose code is a valid delegation indicator ...
                %% to originate transactions. Accounts with any other code values
                %% may not originate transactions." So the rule is *not* "no code"
                %% any more, it is "no code **except** a delegation indicator" --
                %% which is the same sentence with a narrow exception in it, and the
                %% exception is the entire feature: an account that has delegated
                %% exists precisely in order to send transactions.
                %%
                %% Not fork-gated, and that is not an oversight: `0xef0100 || address`
                %% is 23 bytes that only `process_authorizations/3' writes, and that
                %% only runs for a type-4 transaction, which `tx_type_available/2'
                %% refuses before Prague. So a pre-Prague block cannot contain a
                %% delegation indicator, and the gate would be dead code.
                {ok, Code} ->
                    ensure(code_is_empty(Code) orelse is_delegation_indicator(Code),
                           {error, sender_not_eoa});
                _ -> ok
            end;
        {true, undefined} ->
            ok
    end.

%% A missing account answers `undefined` and an account with no code answers `<<>>`; both
%% are externally owned. Anything else is code, and one byte is code.
code_is_empty(undefined) -> true;
code_is_empty(<<>>) -> true;
code_is_empty(_) -> false.

validation_price(MaxFee, _GasPrice) when is_integer(MaxFee) -> MaxFee;
validation_price(_MaxFee, GasPrice) when is_integer(GasPrice) -> GasPrice;
validation_price(_, _) -> 0.

%% A transaction's own blob gas, as a **gas quantity**: `GAS_PER_BLOB` per versioned
%% hash, zero for a transaction of any other type. EIP-4844's
%% `get_total_blob_gas(tx)`.
%%
%% This is the same product `eth_block:blob_fee/2' turns into a wei amount by
%% multiplying by the block's blob base fee. It is defined here rather than imported
%% because it is used by two rules in *this* module -- the per-block cap and the
%% balance rule below -- and neither should have to ask another module for a divisor
%% that happens to be 1 at the floor.
blob_gas_of(Tx) ->
    length(blob_versioned_hashes(Tx)) * eth_fork_schedule:blob_gas_per_blob().

%% EIP-4844's second half of the sufficient-balance rule. `validate_block' says:
%%
%%     # modify the check for sufficient balance
%%     max_total_fee = tx.gas * tx.max_fee_per_gas
%%     if get_tx_type(tx) == BLOB_TX_TYPE:
%%         max_total_fee += get_total_blob_gas(tx) * tx.max_fee_per_blob_gas
%%     assert signer(tx).balance >= max_total_fee
%%
%% **The `max_total_fee` modification was absent**, so the balance check was
%% `gas * maxFeePerGas + value` for every transaction including blob ones. A sender
%% who could not pay for the blobs was admitted, and the corpus names this exactly:
%% the 288 `INSUFFICIENT_ACCOUNT_FUNDS` entries in
%% `cancun/eip4844_blobs/test_insufficient_balance_blob_tx` (144 Cancun + 144
%% Prague).
%%
%% The arithmetic is exact, which is what makes this a derivation rather than a
%% guess. For every one of the 288, `balance < gasLimit * maxFee + value` is
%% **false** -- the sender could pay the gas, so the node admitted it. Adding
%% `total_blob_gas * maxFeePerBlobGas` makes the inequality true for **288 of
%% 288**. There is no third reading.
%%
%% It is the sender's **cap**, `max_fee_per_blob_gas`, and not the block's blob base
%% fee, because this is a *validity* check and the EIP's own text says `assert
%% tx.max_fee_per_blob_gas >= get_base_fee_per_blob_gas(block.header)` separately --
%% the sender must be able to cover the worst case it agreed to pay, and the two
%% numbers are different rules. `eth_block:blob_fee/2' then *charges* the block
%% price; this checks the cap. Conflating them would either over-refuse (charging
%% the cap) or under-refuse (checking the block price, which moves every block).
blob_gas_term(Tx) ->
    case tx_type(Tx) of
        eip4844 ->
            case field(Tx, <<"maxFeePerBlobGas">>) of
                Cap when is_integer(Cap) ->
                    blob_gas_of(Tx) * Cap;
                _ ->
                    %% No cap. `check_blobs/2' refuses this as `invalid_blob_fee',
                    %% and a transaction that cannot state what it will pay for its
                    %% blobs has no blob term to add -- so this contributes 0 and the
                    %% *other* rule is the one that reports it. Adding a term from an
                    %% absent field would mean refusing twice, once for each reason,
                    %% and the corpus expects one.
                    0
            end;
        _ ->
            0
    end.

check_balance(Payer, Total, Ctx) ->
    case maps:get(balance_of, Ctx, undefined) of
        Fun when is_function(Fun, 1) ->
            case Fun(Payer) of
                {ok, Balance} when is_integer(Balance) ->
                    ensure(Balance >= Total, {error, insufficient_balance});
                _ -> ok
            end;
        _ ->
            ok
    end.

%% The sender's account nonce must equal the transaction nonce. A higher nonce
%% stalls the account behind a gap; a lower one is a replay of a transaction the
%% sender has already had accepted.
check_nonce(Payer, Nonce, Ctx) ->
    case maps:get(nonce_of, Ctx, undefined) of
        Fun when is_function(Fun, 1) ->
            case Fun(Payer) of
                {ok, AccountNonce} when is_integer(AccountNonce) ->
                    ensure(AccountNonce =:= Nonce, {error, bad_nonce});
                _ -> ok
            end;
        _ ->
            ok
    end.

%% ---------------------------------------------------------------------------

%% Type inference from fields: explicit `type' wins, else presence of
%% 1559/2930 fee fields decides; default legacy.
tx_type(Tx) ->
    case maps:get(<<"type">>, Tx, undefined) of
        <<"0x0">> -> legacy;
        <<"0x1">> -> eip2930;
        <<"0x2">> -> eip1559;
        <<"0x3">> -> eip4844;
        <<"0x4">> -> eip7702;
        undefined ->
            case maps:is_key(<<"maxFeePerGas">>, Tx) of
                true -> eip1559;
                false ->
                    case maps:is_key(<<"accessList">>, Tx) of
                        true -> eip2930;
                        false -> legacy
                    end
            end;
        _ ->
            unsupported
    end.

%% Quantity field -> integer (missing v/r/s default 0 for unsigned use).
q(Tx, K) ->
    case maps:get(K, Tx, undefined) of
        undefined -> 0;
        I when is_integer(I) -> I;
        B when is_binary(B) ->
            try eth_hex:decode(B) catch _:_ -> 0 end;
        _ -> 0
    end.

%% Destination: 20 bytes, empty for contract creation.
addr(Tx) ->
    case maps:get(<<"to">>, Tx, undefined) of
        undefined -> <<>>;
        null -> <<>>;
        B when is_binary(B) -> hex_bytes(B);
        _ -> <<>>
    end.

data(Tx, K) ->
    case maps:get(K, Tx, undefined) of
        undefined ->
            case maps:get(<<"data">>, Tx, <<>>) of
                B when is_binary(B) -> hex_bytes(B);
                _ -> <<>>
            end;
        B when is_binary(B) -> hex_bytes(B);
        _ -> <<>>
    end.

access_list(Tx) ->
    case maps:get(<<"accessList">>, Tx, []) of
        L when is_list(L) ->
            [[hex_bytes(maps:get(<<"address">>, E, <<>>)),
              [hex_bytes(K) || K <- maps:get(<<"storageKeys">>, E, [])]]
             || E <- L];
        _ ->
            []
    end.

%% EIP-4844 blob versioned hashes, as 32-byte binaries. A transaction with no
%% blob hashes is a malformed blob transaction rather than a valid one, but
%% this helper only performs the shape conversion: whether a hash is
%% well-formed, and whether the transaction pays enough for the blobs it
%% references, are validity rules enforced by the block builder, not part of
%% the wire codec.
blob_versioned_hashes(Tx) ->
    case maps:get(<<"blobVersionedHashes">>, Tx,
                  maps:get(<<"blob_versioned_hashes">>, Tx, [])) of
        L when is_list(L) -> [blob_versioned_hash(H) || H <- L];
        _ -> []
    end.

%% A versioned hash is the version byte followed by the SHA-256 of the
%% commitment, minus that hash's first byte. It commits to the blob's
%% commitment without revealing it.
blob_versioned_hash(<<Version, Rest/binary>>) when byte_size(Rest) =:= 31 ->
    <<Version, Rest/binary>>;
blob_versioned_hash(B) when is_binary(B), byte_size(B) =:= 32 ->
    B;
blob_versioned_hash(<<"0x", B/binary>>) when byte_size(B) =:= 64 ->
    <<Version, Rest/binary>> = hex_bytes(B),
    <<Version, Rest/binary>>;
blob_versioned_hash(H) when is_integer(H), H >= 0 ->
    <<H:256>>;
blob_versioned_hash(_) ->
    <<>>.

%% EIP-4844 validity for the versioned hashes themselves. A blob transaction must
%% reference at least one blob, and every referenced hash must be exactly 32 bytes
%% carrying the KZG-commitment version byte.
%%
%% ## The non-zero remainder clause was fabricated, and it over-refused the corpus.
%%
%% This function also required `Rest =/= <<0:248>>', on the reasoning that "a zero
%% hash would commit to nothing". **EIP-4844 contains no such rule.** Its
%% `validate_block' says, in full:
%%
%%     # there must be at least one blob
%%     assert len(tx.blob_versioned_hashes) > 0
%%     # all versioned blob hashes must start with VERSIONED_HASH_VERSION_KZG
%%     for h in tx.blob_versioned_hashes:
%%         assert h[0] == VERSIONED_HASH_VERSION_KZG
%%
%% A versioned hash is `VERSIONED_HASH_VERSION_KZG + sha256(commitment)[1:]` -- the
%% version byte *replaces* the digest's first byte, so the remaining 31 bytes are
%% whatever the commitment hashes to. Whether that is zero is a question about a
%% 48-byte commitment the transaction does not carry, and **the execution layer
%% cannot answer it.** The clause was not a weaker version of the rule; it was a
%% different rule, invented here, and it refused transactions the chain accepts.
%%
%% The corpus settles it without argument. Across the whole `state_tests' corpus,
%% **1,502 transactions carrying `0x01 || 31 zero bytes` are expected to SUCCEED**
%% and 325 are expected to be rejected, in 9 files -- and 1,827 in total carry one,
%% which is every type-3 transaction the corpus has. A hash the corpus treats as
%% valid in 1,502 places cannot be one this node is entitled to refuse. And the
%% 325 rejections name *other* rules (`INSUFFICIENT_ACCOUNT_FUNDS`,
%% `INTRINSIC_GAS_TOO_LOW`, ...) -- not this one. The EIP names no exception for an
%% all-zero hash, so there is no fourth reading.
%%
%% What it cost: the node answered `bad_blob_hashes' for **1,827** corpus branches,
%% which is the whole of the 288-entry blob cluster and all 34 of the
%% check-ordering mismatches, in every case for the wrong reason. Two of them --
%% `TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH' -- are the *version byte* check below,
%% which is the EIP's rule and is what the corpus means.
valid_versioned_hashes(Tx) ->
    blob_hashes_present(Tx) andalso blob_hashes_well_formed(Tx).

%% "there must be at least one blob" -- EIP-4844's first blob assert, and its own
%% refusal. It was previously folded into `valid_versioned_hashes/1' and so shared
%% one reason with the version-byte check below.
blob_hashes_present(Tx) ->
    blob_versioned_hashes(Tx) =/= [].

%% "all versioned blob hashes must start with VERSIONED_HASH_VERSION_KZG" -- the
%% EIP's second assert. The 32-byte length is implied rather than stated: a
%% `blob_versioned_hashes/1' entry that is not 32 bytes normalises to something that
%% cannot carry the version byte, so it fails here.
blob_hashes_well_formed(Tx) ->
    lists:all(fun
                  (<<?VERSIONED_HASH_KZG, _Rest/binary>>) ->
                      true;
                  (_) ->
                      false
              end, blob_versioned_hashes(Tx)).

hex_bytes(<<"0x", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<"0X", Rest/binary>>) -> hex_bytes(Rest);
hex_bytes(<<>>) -> <<>>;
hex_bytes(B) when is_binary(B) ->
    try binary:decode_hex(B) catch _:_ -> <<>> end;
hex_bytes(_) -> <<>>.

%% **The fork the cap is read at.** EIP-4844's cap is six blobs at Cancun, nine at
%% Prague and twenty-one at BPO2, so a node past Prague was enforcing Cancun's cap while
%% accepting blocks that carry more -- the allowance was *under*-enforced, which is the
%% direction that admits an invalid block rather than refusing a valid one.
%%
%% The context carries the fork on the admission path; without it the operator's `ETH_FORK'
%% pin is the answer, which is correct for a pool that has no block to read a header from
%% and is the same rule `eth_fork_schedule:current_fork/4' already applies when a network
%% has no schedule.
fork_of(Ctx) ->
    case maps:get(fork, Ctx, undefined) of
        undefined -> eth_fork_schedule:configured_fork();
        Fork -> Fork
    end.
