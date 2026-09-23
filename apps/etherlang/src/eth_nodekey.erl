-module(eth_nodekey).

%% Static node identity shared by discv4 and RLPx. The 32-byte private key
%% is persisted under DATA_DIR/nodekey (0600) so the enode URL stays stable
%% across restarts; a missing or corrupt file falls back to an ephemeral key.

-export([load_or_generate/1]).

load_or_generate(DataDir) ->
    Path = filename:join(DataDir, "nodekey"),
    case file:read_file(Path) of
        {ok, Key} when byte_size(Key) =:= 32 ->
            case valid(Key) of
                true -> Key;
                false -> ephemeral(Path)
            end;
        _ ->
            ephemeral(Path)
    end.

valid(Key) ->
    I = binary:decode_unsigned(Key),
    I > 0 andalso I < 16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141.

ephemeral(Path) ->
    Key = eth_secp256k1:generate_key(),
    ok = filelib:ensure_dir(Path),
    case file:write_file(Path, Key, [{mode, 8#600}]) of
        ok -> ok;
        {error, Reason} ->
            logger:warning("etherlang: cannot persist nodekey (~p); using ephemeral key", [Reason])
    end,
    Key.
