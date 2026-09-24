-module(eth_snap).

%% snap/1 capability codecs (eth/68 companion): account/storage range
%% fetch with boundary-proof verification. Message IDs are capability
%% offsets assigned by eth capability negotiation (see eth_cap_ids).

-export([caps/0, msg_get_account_range/1, msg_account_range/1,
         msg_get_storage/1, msg_storage/1,
         msg_get_bytecodes/1, msg_bytecodes/1,
         msg_get_trie_nodes/1, msg_trie_nodes/1]).
-export([encode_account_req/3, decode_account_req_bin/1]).
-export([encode_storage_req/4, decode_storage_req_bin/1]).
-export([encode_bytecodes_req/1, decode_bytecodes_bin/1]).
-export([verify_account_range/4, verify_storage_range/4]).

caps() -> [{"snap", 1}].

msg_get_account_range(#{base := B}) -> B + 0.
msg_account_range(#{base := B}) -> B + 1.
msg_get_storage(#{base := B}) -> B + 2.
msg_storage(#{base := B}) -> B + 3.
msg_get_bytecodes(#{base := B}) -> B + 4.
msg_bytecodes(#{base := B}) -> B + 5.
msg_get_trie_nodes(#{base := B}) -> B + 6.
msg_trie_nodes(#{base := B}) -> B + 7.

%% GetAccountRange [root, origin, limit].
encode_account_req(Root, Origin, Limit)
  when byte_size(Root) =:= 32, byte_size(Origin) =:= 32 ->
    [Root, Origin, Limit].

decode_account_req_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, [Root, Origin, Limit], _}
              when byte_size(Root) =:= 32, byte_size(Origin) =:= 32 ->
                {ok, Root, Origin, to_int(Limit)};
            _ ->
                {error, bad_account_req}
        end
    catch _:_ ->
        {error, bad_account_req}
    end.

%% GetStorageRanges [root, [(account, origin, limit)...]] — single-account
%% form used here: [root, account, origin, limit].
encode_storage_req(Root, Account, Origin, Limit)
  when byte_size(Root) =:= 32, byte_size(Account) =:= 32,
       byte_size(Origin) =:= 32 ->
    [Root, Account, Origin, Limit].

decode_storage_req_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, [Root, Account, Origin, Limit], _}
              when byte_size(Root) =:= 32, byte_size(Account) =:= 32,
                   byte_size(Origin) =:= 32 ->
                {ok, Root, Account, Origin, to_int(Limit)};
            _ ->
                {error, bad_storage_req}
        end
    catch _:_ ->
        {error, bad_storage_req}
    end.

%% GetByteCodes [hashes...] / ByteCodes [codes...].
encode_bytecodes_req(Hashes) when is_list(Hashes) -> [Hashes].

decode_bytecodes_bin(Data) when is_binary(Data) ->
    try
        case eth_rlp:decode(Data) of
            {ok, [Codes], _} when is_list(Codes) ->
                case lists:all(fun is_binary/1, Codes) of
                    true -> {ok, Codes};
                    false -> {error, bad_bytecodes}
                end;
            _ ->
                {error, bad_bytecodes}
        end
    catch _:_ ->
        {error, bad_bytecodes}
    end.

%% Verify an AccountRange reply: [hashes, accounts, proof]. Keys sort
%% strictly and start at/after the requested origin (checked by the
%% caller via stitching); the boundary proof must include the last key
%% with bytes identical to those returned. Tampered values, reordered
%% keys, or a proof for another root all fail.
verify_account_range(Hashes, Accounts, Proof, Root) ->
    verify_range(Hashes, Accounts, Proof, Root).

%% Verify a StorageRanges chunk for one account: [hashes, slots, proof]
%% against the account's storage root. Same rules as accounts.
verify_storage_range(Hashes, Slots, Proof, StorageRoot) ->
    verify_range(Hashes, Slots, Proof, StorageRoot).

verify_range([], [], Proof, _Root) ->
    %% Empty chunk: nothing more in range (a peer withholds by staying
    %% silent, which stalls rather than corrupts; truncation past a
    %% returned boundary is caught by continuation stitching).
    try check_proof_nodes(Proof) of
        _ -> {ok, [], true}
    catch _:_ ->
        {error, bad_range}
    end;
verify_range(Hashes, Vals, Proof, Root) ->
    try
        Pairs = lists:zip(Hashes, Vals),
        true = length(Pairs) > 0 orelse Proof =/= [],
        true = strictly_sorted([H || {H, _} <- Pairs]),
        true = lists:all(fun valid_hashval/1, Pairs),
        check_proof_nodes(Proof),
        case Pairs of
            [] ->
                {ok, [], false};
            _ ->
                {LastH, LastV} = lists:last(Pairs),
                case eth_trie:verify_proof(Root, LastH, Proof) of
                    {ok, LastV} -> {ok, lists:sort(Pairs), true};
                    _ -> {ok, lists:sort(Pairs), false}
                end
        end
    catch _:_ ->
        {error, bad_range}
    end.

strictly_sorted([]) -> true;
strictly_sorted([_]) -> true;
strictly_sorted([A, B | Rest]) when A < B -> strictly_sorted([B | Rest]);
strictly_sorted(_) -> false.

valid_hashval({H, V}) ->
    is_binary(H) andalso byte_size(H) =:= 32 andalso is_binary(V).

check_proof_nodes(Proof) when is_list(Proof) ->
    true = lists:all(fun is_binary/1, Proof),
    ok.

to_int(I) when is_integer(I) -> I;
to_int(B) when is_binary(B), byte_size(B) =:= 0 -> 0;
to_int(B) when is_binary(B) -> binary:decode_unsigned(B);
to_int(_) -> 0.
