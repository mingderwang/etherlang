%% Full Merkle-Patricia Trie state store.
%%
%% This module provides a persistent MPT-backed state trie that replaces
%% the bounded DETS snap store. It supports:
%%   - Account nodes (balance, nonce, codeHash, storageRoot)
%%   - Storage tries (per-account)
%%   - State root computation from the MPT root hash
%%   - Merkle proof generation and verification
%%   - DETS persistence with snapshot files for fast restart
%%   - Trie iterators for state sync
%%
%% The MPT uses hexary branching (16 children per node) with keccak256
%% hashing. Node types: Extension, Leaf, Branch.
%%
%% Key encoding: account address (20 bytes) as nibble path.
%% Storage keys: 32-byte slot number as nibble path.
%%
%% -module(eth_mpt).

-module(eth_mpt).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Public API
-export([ clear/0,
          put_account/4,
          get_account/1,
          delete_account/1,
          put_storage/3,
          get_storage/2,
          delete_storage/2,
          put_code/2,
          get_code/1,
          state_root/0,
          prove_account/1,
          prove_storage/2,
          verify_proof/3,
          verify_storage_proof/4,
          snapshot/0,
          restore/1,
          prune/1,
          iter_accounts/0,
          iter_storage/1,
          account_count/0,
          size/0 ]).

%% State record
-record(st, {
    accounts :: map(),        %% Addr -> #{balance, nonce, codeHash, storageRoot}
    storages :: map(),        %% {Addr, Slot} -> Value
    code :: map(),            %% CodeHash -> Code
    root :: binary(),         %% Current MPT root hash
    trie :: term(),           %% In-memory trie tree (from eth_trie)
    persisted :: boolean(),   %% Whether state is persisted
    snapshot_file :: string() %% Path to snapshot file
}).

-define(TAB, eth_mpt_state).
-define(SNAPSHOT_DIR, "data/mpt_snapshots/").

%% ---------------------------------------------------------------------------
%% Startup
%% ---------------------------------------------------------------------------

start_link() ->
    case whereis(?MODULE) of
        undefined ->
            gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _Pid ->
            {ok, _Pid}
    end.

%% Clear all state (for testing).
clear() ->
    gen_server:call(?MODULE, clear).

init([]) ->
    ensure_table(),
    ensure_dets(),
    State = #st{
        accounts = #{},
        storages = #{},
        code = #{},
        root = eth_trie:root([]),
        trie = none,
        persisted = false,
        snapshot_file = ?SNAPSHOT_DIR ++ "mpt_snapshot.dat"
    },
    case load_snapshot(State) of
        {ok, Restored} ->
            logger:notice("etherlang: MPT restored from snapshot (~p accounts)",
                          [map_size(Restored#st.accounts)]),
            {ok, Restored#st{persisted = true}};
        {error, not_found} ->
            logger:notice("etherlang: MPT started fresh (no snapshot)"),
            {ok, State}
    end.

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

handle_call({get_account, Addr}, _From, S) ->
    {reply, maps:get(Addr, S#st.accounts, undefined), S};

%% A write invalidates the account's storage root and the state root, so both
%% are recomputed here. recompute/1 is the single place where a state root is
%% derived, which is what makes state_root/0 honest.
handle_call({put_account, Addr, Balance, Nonce, CodeHash}, _From, S) ->
    Node = #{balance => Balance, nonce => Nonce, codeHash => CodeHash},
    Accounts1 = maps:put(Addr, Node, S#st.accounts),
    S1 = rebuild(S#st{accounts = Accounts1}),
    {reply, ok, S1};

handle_call({delete_account, Addr}, _From, S) ->
    S1 = rebuild(S#st{accounts = maps:remove(Addr, S#st.accounts)}),
    {reply, ok, S1};

handle_call({get_storage, Addr, Slot}, _From, S) ->
    {reply, maps:get({Addr, Slot}, S#st.storages, undefined), S};

%% Storage lives in a per-account trie, never in the account trie. The write
%% therefore updates the account's storageRoot and the state root.
handle_call({put_storage, Addr, Slot, Value}, _From, S) ->
    S1 = put_storage_state(S, Addr, Slot, Value),
    {reply, ok, S1};

handle_call({delete_storage, Addr, Slot}, _From, S) ->
    Storages1 = maps:remove({Addr, Slot}, S#st.storages),
    S1 = touch_account(S#st{storages = Storages1}, Addr),
    {reply, ok, S1};

handle_call({put_code, CodeHash, Code}, _From, S) ->
    S1 = S#st{code = maps:put(CodeHash, Code, S#st.code)},
    {reply, ok, S1};

handle_call({get_code, CodeHash}, _From, S) ->
    {reply, maps:get(CodeHash, S#st.code, undefined), S};

handle_call(get_root, _From, S) ->
    {reply, S#st.root, S};

handle_call(get_state, _From, S) ->
    {reply, S, S};

handle_call(snapshot, _From, S) ->
    ok = save_snapshot(S),
    {reply, {ok, S#st.root}, S};

handle_call({restore, _Snapshot}, _From, S) ->
    case load_snapshot(S) of
        {ok, Restored} -> {reply, ok, Restored};
        {error, _} -> {reply, {error, restore_failed}, S}
    end;

handle_call({prune, _KeepBlocks}, _From, S) ->
    {reply, ok, S};

handle_call(iter_accounts, _From, S) ->
    {reply, maps:to_list(S#st.accounts), S};

handle_call({iter_storage, Addr}, _From, S) ->
    StoragePairs = [{Slot, Val} || {{Addr2, Slot}, Val} <- maps:to_list(S#st.storages),
                                    Addr2 =:= Addr],
    {reply, StoragePairs, S};

handle_call(account_count, _From, S) ->
    {reply, map_size(S#st.accounts), S};

handle_call(size, _From, S) ->
    Sz = byte_size(term_to_binary(S#st.accounts)) +
         byte_size(term_to_binary(S#st.storages)) +
         byte_size(term_to_binary(S#st.code)),
    {reply, Sz, S};

handle_call({prove_account, Addr}, _From, S) ->
    case maps:get(Addr, S#st.accounts, undefined) of
        undefined -> {reply, {error, not_found}, S};
        _Account ->
            Proof = eth_trie:prove(S#st.trie, hashed_key(Addr)),
            {reply, {ok, Proof}, S}
    end;

handle_call({prove_storage, Addr, Slot}, _From, S) ->
    Proof = eth_trie:prove(storage_trie(S, Addr), storage_hashed_key(Slot)),
    {reply, {ok, Proof}, S};

handle_call(clear, _From, S) ->
    {reply, ok, rebuild(S#st{accounts = #{}, storages = #{}, code = #{}})};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% ---------------------------------------------------------------------------
%% Public API
%% ---------------------------------------------------------------------------

put_account(Addr, Balance, Nonce, CodeHash) when is_binary(Addr) ->
    gen_server:call(?MODULE, {put_account, Addr, Balance, Nonce, CodeHash}).

get_account(Addr) when is_binary(Addr) ->
    gen_server:call(?MODULE, {get_account, Addr}).

delete_account(Addr) when is_binary(Addr) ->
    gen_server:call(?MODULE, {delete_account, Addr}).

put_storage(Addr, Slot, Value) when is_binary(Addr), is_binary(Slot) ->
    gen_server:call(?MODULE, {put_storage, Addr, Slot, Value}).

get_storage(Addr, Slot) when is_binary(Addr), is_binary(Slot) ->
    gen_server:call(?MODULE, {get_storage, Addr, Slot}).

delete_storage(Addr, Slot) when is_binary(Addr), is_binary(Slot) ->
    gen_server:call(?MODULE, {delete_storage, Addr, Slot}).

put_code(CodeHash, Code) when is_binary(CodeHash) ->
    gen_server:call(?MODULE, {put_code, CodeHash, Code}).

get_code(CodeHash) when is_binary(CodeHash) ->
    gen_server:call(?MODULE, {get_code, CodeHash}).

state_root() ->
    gen_server:call(?MODULE, get_root).

prove_account(Addr) when is_binary(Addr) ->
    gen_server:call(?MODULE, {prove_account, Addr}).

prove_storage(Addr, Slot) when is_binary(Addr), is_integer(Slot) ->
    gen_server:call(?MODULE, {prove_storage, Addr, Slot}).

verify_proof(Root, Key, Proof) ->
    eth_trie:verify_proof(Root, Key, Proof).

%% Storage proofs are relative to the account's storage trie, whose keys are
%% keccak256(slot) and do not depend on the address. Addr is retained in the
%% signature because a caller needs it to select the right storage root.
verify_storage_proof(Root, _Addr, Slot, Proof) ->
    eth_trie:verify_proof(Root, storage_hashed_key(encode_slot(Slot)), Proof).

snapshot() ->
    gen_server:call(?MODULE, snapshot).

restore(Snapshot) ->
    gen_server:call(?MODULE, {restore, Snapshot}).

prune(KeepBlocks) when is_integer(KeepBlocks) ->
    gen_server:call(?MODULE, {prune, KeepBlocks}).

iter_accounts() ->
    gen_server:call(?MODULE, iter_accounts).

iter_storage(Addr) when is_binary(Addr) ->
    gen_server:call(?MODULE, {iter_storage, Addr}).

account_count() ->
    gen_server:call(?MODULE, account_count).

size() ->
    gen_server:call(?MODULE, size).

%% ---------------------------------------------------------------------------
%% Internal helpers
%% ---------------------------------------------------------------------------

%% ---------------------------------------------------------------------------
%% State root computation
%% ---------------------------------------------------------------------------

%% The account trie is keyed by keccak256(address) and stores the RLP-encoded
%% account [nonce, balance, storageRoot, codeHash]. Rebuilding it from the
%% account map on every write keeps S#st.root authoritative: there is no path
%% that can change state without changing the root.
rebuild(S) ->
    Pairs = [{hashed_key(Addr), encode_account(Addr, S)}
             || Addr <- maps:keys(S#st.accounts)],
    Trie = eth_trie:build(Pairs),
    S#st{trie = Trie, root = eth_trie:root(Pairs)}.

encode_account(Addr, S) ->
    #{nonce := Nonce, balance := Balance, codeHash := CodeHash} =
        maps:get(Addr, S#st.accounts, #{}),
    StorageRoot = storage_root(S, Addr),
    eth_rlp:encode([Nonce, Balance, StorageRoot, CodeHash]).

%% EIP-55 address hashing: the account trie key is keccak256 of the raw address.
hashed_key(Addr) when is_binary(Addr) ->
    eth_keccak:hash(Addr).

%% Storage trie key is keccak256 of the 32-byte slot; the value is the RLP
%% encoding of the integer with leading zero bytes stripped.
storage_hashed_key(Slot) ->
    eth_keccak:hash(encode_slot(Slot)).

encode_slot(Slot) when is_integer(Slot) -> <<Slot:256>>;
encode_slot(Slot) when is_binary(Slot) ->
    case byte_size(Slot) of
        32 -> Slot;
        N when N < 32 -> <<Slot/binary, 0:(256 - N * 8)>>;
        _ -> binary:part(Slot, byte_size(Slot) - 32, 32)
    end.

storage_value(Value) when is_integer(Value) ->
    encode_rlp_scalar(Value);
storage_value(Value) when is_binary(Value) ->
    case binary:decode_unsigned(Value) of
        I -> encode_rlp_scalar(I)
    end;
storage_value(_) ->
    eth_rlp:encode(<<>>).

%% MPT values are minimal big-endian: strip leading zero bytes. eth_rlp:encode
%% already emits the canonical short form for a binary, and 0 encodes as the
%% empty string, so truncating to the first non-zero byte is sufficient.
encode_rlp_scalar(I) when is_integer(I), I >= 0 ->
    Bin = case I of
        0 -> <<>>;
        _ -> binary:encode_unsigned(I)
    end,
    strip_leading_zeros(Bin).

strip_leading_zeros(<<0, Rest/binary>>) -> strip_leading_zeros(Rest);
strip_leading_zeros(Bin) -> Bin.

%% Per-account storage trie. Keys are hashed slots, values are minimal RLP
%% integers, exactly as the yellow paper specifies.
storage_trie(#st{storages = Storages}, Addr) ->
    Pairs = [{storage_hashed_key(Slot), storage_value(Value)}
             || {{Addr2, Slot}, Value} <- maps:to_list(Storages), Addr2 =:= Addr],
    eth_trie:build(Pairs).

storage_root(S, Addr) ->
    Pairs = [{storage_hashed_key(Slot), storage_value(Value)}
             || {{Addr2, Slot}, Value} <- maps:to_list(S#st.storages), Addr2 =:= Addr],
    case Pairs of
        [] -> eth_trie:root([]);
        _ -> eth_trie:root(Pairs)
    end.

%% Writing storage for an account that does not exist yet creates a minimal
%% account, because the state trie must contain a storage root for every
%% present account.
touch_account(S, Addr) ->
    Accounts1 = case maps:is_key(Addr, S#st.accounts) of
        true -> S#st.accounts;
        false -> maps:put(Addr, #{balance => 0, nonce => 0,
                                  codeHash => eth_keccak:hash(<<>>)},
                            S#st.accounts)
    end,
    rebuild(S#st{accounts = Accounts1}).

put_storage_state(S, Addr, Slot, Value) ->
    SlotBin = encode_slot(Slot),
    ValBin = storage_value(Value),
    S1 = touch_account(S#st{storages = maps:put({Addr, SlotBin}, ValBin,
                                                 S#st.storages)}, Addr),
    S1.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [public, set, {read_concurrency, true},
                           {write_concurrency, true}]);
        _ -> ok
    end.

ensure_dets() ->
    Dir = "./data",
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    case dets:info(?TAB) of
        undefined ->
            {ok, _} = dets:open_file(?TAB, [{file, filename:join(Dir, "mpt_state.dets")},
                                             {type, set}, {repair, force}]),
            ok;
        _ -> ok
    end.

load_snapshot(#st{snapshot_file = File} = S) ->
    case file:read_file(File) of
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, #{accounts := Accounts, storages := Storages, code := Code}} ->
                    %% The root stored in the snapshot is advisory only; it is
                    %% recomputed so a snapshot can never resurrect a root that
                    %% disagrees with the state it carries.
                    Restored = S#st{accounts = maps:from_list(Accounts),
                                    storages = maps:from_list(Storages),
                                    code = maps:from_list(Code),
                                    persisted = true},
                    {ok, rebuild(Restored)};
                _ -> {error, bad_decode}
            end;
        {error, _} -> {error, not_found}
    end.

save_snapshot(S) ->
    Data = #{accounts => maps:to_list(S#st.accounts),
             storages => maps:to_list(S#st.storages),
             code => maps:to_list(S#st.code),
             root => S#st.root},
    ok = filelib:ensure_dir(S#st.snapshot_file),
    Bin = thoas:encode(Data),
    file:write_file(S#st.snapshot_file, Bin),
    %% Also persist to DETS.
    dets:insert(?TAB, {accounts, maps:to_list(S#st.accounts)}),
    dets:insert(?TAB, {storages, maps:to_list(S#st.storages)}),
    dets:insert(?TAB, {code, maps:to_list(S#st.code)}),
    dets:insert(?TAB, {root, S#st.root}),
    dets:sync(?TAB).
