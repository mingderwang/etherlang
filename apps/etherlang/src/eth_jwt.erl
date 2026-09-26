%% JWT verification for the Engine API.
%%
%% The scheme is specified in execution-apis, src/engine/authentication.md. The
%% parts of that document that constrain an implementation:
%%
%%   - the Engine API is authenticated by a JWT in the HTTP header, per request
%%   - `alg` HMAC + SHA256 (`HS256`) must be supported
%%   - `alg' `none' must be rejected
%%   - the `iat' claim is required, and `iat' timestamps more than +-60 seconds
%%     from now should not be accepted
%%   - `id' and `clv' are optional, and unrecognised claims must be ignored
%%   - the key is a hex-encoded 256-bit secret; if none is configured the client
%%     should generate one and store the hex-encoded secret as `jwt.hex'
%%
%% This module existed nowhere. The engine handler's header comment claimed
%% "JWT authentication is enforced when JWT_SECRET is configured" and TASKS.md
%% ticked "Engine API authentication -- JWT secret via JWT_SECRET env var,
%% HMAC-SHA256 verification" as done, but no code read a secret or verified a
%% token: `eth_config' had no jwt function, and the only trace of the scheme was
%% an unused `jwt_secret' field on the engine's record. The engine API is a
%% network port, so that left it unauthenticated while the documentation described
%% it as authenticated.
-module(eth_jwt).

-export([load_or_create_secret/1, verify/2, sign/2,
         b64url_encode/1, b64url_decode/1]).

-define(SECRET_BYTES, 32).
-define(SECRET_FILE, "jwt.hex").
-define(IAT_SKEW_SECONDS, 60).

%% ---------------------------------------------------------------------------
%% Key material
%% ---------------------------------------------------------------------------

%% Read the hex-encoded 256-bit secret from Dir/jwt.hex, generating and storing
%% one if it is not there. The specification asks for exactly this: a client given
%% no `jwt-secret' should generate a token and store the hex-encoded secret as
%% jwt.hex so it can be provisioned to the counterpart client.
%%
%% A file that exists but is not a 32-byte hex key is an error rather than
%% something to regenerate, because regenerating would silently invalidate every
%% consensus client already provisioned with the old key.
load_or_create_secret(Dir) ->
    Path = filename:join(Dir, ?SECRET_FILE),
    case file:read_file(Path) of
        {ok, Bin} ->
            decode_secret(Bin, Path);
        {error, enoent} ->
            create_secret(Path);
        {error, Reason} ->
            {error, {cannot_read_secret, Path, Reason}}
    end.

create_secret(Path) ->
    Secret = crypto:strong_rand_bytes(?SECRET_BYTES),
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, hex(Secret)) of
                ok ->
                    logger:notice("etherlang: generated engine API JWT secret at ~s", [Path]),
                    {ok, Secret};
                {error, Reason} ->
                    {error, {cannot_write_secret, Path, Reason}}
            end;
        {error, Reason} ->
            {error, {cannot_create_secret_dir, Path, Reason}}
    end.

decode_secret(Bin, Path) ->
    Trimmed = string:trim(Bin),
    try binary:decode_hex(Trimmed) of
        Secret when byte_size(Secret) =:= ?SECRET_BYTES ->
            {ok, Secret};
        Other ->
            {error, {secret_wrong_length, Path, byte_size(Other)}}
    catch
        _:_ -> {error, {secret_not_hex, Path}}
    end.

%% ---------------------------------------------------------------------------
%% Verification
%% ---------------------------------------------------------------------------

verify(Token, Secret) when is_binary(Token), is_binary(Secret) ->
    case binary:split(Token, <<".">>, [global]) of
        [Header, Payload, Signature] ->
            verify_parts(Header, Payload, Signature, Secret);
        _ ->
            {error, malformed_token}
    end;
verify(_Token, _Secret) ->
    {error, malformed_token}.

verify_parts(Header, Payload, Signature, Secret) ->
    case {b64url_decode(Header), b64url_decode(Payload), b64url_decode(Signature)} of
        {{ok, HeaderJson}, {ok, PayloadJson}, {ok, Given}} ->
            with_alg(HeaderJson,
                fun() ->
                    SigningInput = <<Header/binary, $., Payload/binary>>,
                    case check_signature(SigningInput, Given, Secret) of
                        ok -> check_iat(PayloadJson);
                        {error, _} = E -> E
                    end
                end);
        _ ->
            {error, malformed_token}
    end.

%% `alg: none' is explicitly rejected by the specification, and an unsecured JWT
%% is the whole attack this scheme exists to stop, so it is refused before the
%% signature is even considered.
with_alg(HeaderJson, Fun) ->
    case json_field(HeaderJson, <<"alg">>) of
        {ok, <<"HS256">>} -> Fun();
        {ok, <<"none">>} -> {error, unsigned_token};
        {ok, Alg} -> {error, {unsupported_alg, Alg}};
        {error, Reason} -> {error, Reason}
    end.

check_signature(SigningInput, Given, Secret) ->
    Expected = crypto:mac(hmac, sha256, Secret, SigningInput),
    case crypto:hash_equals(Expected, Given) of
        true -> ok;
        false -> {error, bad_signature}
    end.

check_iat(PayloadJson) ->
    case json_field(PayloadJson, <<"iat">>) of
        {ok, Iat} when is_integer(Iat) ->
            Now = os:system_time(second),
            case abs(Now - Iat) of
                Skew when Skew =< ?IAT_SKEW_SECONDS -> ok;
                _ -> {error, {iat_out_of_range, Iat}}
            end;
        {ok, Other} ->
            {error, {iat_not_a_timestamp, Other}};
        {error, Reason} ->
            {error, Reason}
    end.

json_field(Json, Field) ->
    case thoas:decode(Json) of
        {ok, Map} when is_map(Map) ->
            case maps:find(Field, Map) of
                {ok, Value} -> {ok, Value};
                error -> {error, {missing_claim, Field}}
            end;
        _ ->
            {error, not_json}
    end.

%% ---------------------------------------------------------------------------
%% Signing
%% ---------------------------------------------------------------------------

%% Only used by the tests, to prove the verifier accepts a correctly signed
%% token. The node never issues tokens: it verifies the ones the consensus
%% client sends.
sign(PayloadJson, Secret) ->
    Header = thoas:encode(#{<<"alg">> => <<"HS256">>, <<"typ">> => <<"JWT">>}),
    Payload = case PayloadJson of
        Bin when is_binary(Bin) -> Bin;
        Map when is_map(Map) -> thoas:encode(Map)
    end,
    B64Header = b64url_encode(Header),
    B64Payload = b64url_encode(Payload),
    SigningInput = <<B64Header/binary, $., B64Payload/binary>>,
    Signature = crypto:mac(hmac, sha256, Secret, SigningInput),
    <<SigningInput/binary, $., (b64url_encode(Signature))/binary>>.

%% ---------------------------------------------------------------------------
%% base64url
%% ---------------------------------------------------------------------------
%%
%% RFC 7515 uses the URL-safe alphabet with no padding. `base64/1' is the
%% standard alphabet, so each direction is a translation.

b64url_encode(Bin) when is_binary(Bin) ->
    Encoded = base64:encode(Bin),
    <<Stripped/binary>> = strip_padding(Encoded),
    Translated = translate(Stripped, <<"+">>, <<"-">>, <<"/">>, <<"_">>),
    iolist_to_binary(Translated).

b64url_decode(Bin) when is_binary(Bin) ->
    Standard = translate(Bin, <<"-">>, <<"+">>, <<"_">>, <<"/">>),
    try
        {ok, base64:decode(pad(Standard))}
    catch
        _:_ -> {error, not_base64url}
    end.

%% binary:split/3 returns a list; the segment before the first '=' is what a
%% base64url encoding is. Binding the list against a binary pattern fails for
%% every input, so this returned nothing at all and every token was unencodable.
strip_padding(Encoded) ->
    hd(binary:split(Encoded, <<"=">>, [global])).

pad(Bin) ->
    case byte_size(Bin) rem 4 of
        0 -> Bin;
        2 -> <<Bin/binary, "==">>;
        3 -> <<Bin/binary, "=">>;
        1 -> Bin
    end.

%% A byte-for-byte substitution over the two characters that differ between the
%% alphabets.
%%
%% The comparison has to be integer-to-integer. Comparing the byte from the
%% comprehension against a one-byte binary is false for every input, so the
%% translation silently did nothing and `b64url_encode/1' returned the *standard*
%% alphabet. Nothing raised: an encoding that skips its one step still produces a
%% plausible-looking string, and only a decoder using the other alphabet can tell.
translate(Bin, From1, To1, From2, To2) ->
    F1 = char(From1), T1 = char(To1),
    F2 = char(From2), T2 = char(To2),
    << <<(translate_char(C, F1, T1, F2, T2))>> || <<C>> <= Bin >>.

translate_char(C, F1, T1, F2, T2) ->
    case C =:= F1 of
        true -> T1;
        false ->
            case C =:= F2 of
                true -> T2;
                false -> C
            end
    end.

char(<<C>>) -> C.

hex(Bin) ->
    iolist_to_binary(binary:encode_hex(Bin)).
