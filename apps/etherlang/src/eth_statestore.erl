-module(eth_statestore).
-behaviour(gen_server).

%% Local state-trie data landed by snap sync: accounts (by address hash),
%% storage slots (by account+slot hash) and contract code (by code hash).
%% ETS ordered_set for range serving + DETS persistence. Not a full trie:
%% proofs are verified at ingest (see eth_snap), the store holds leaves.

-export([start_link/1, put_accounts/1, put_accounts/2]).
-export([get_account/1, get_account/2, account_range/3, account_range/4]).
-export([put_storage/2, put_storage/3, get_storage/2, get_storage/3,
         storage_range/4, storage_range/5]).
-export([put_code/2, put_code/3, get_code/1, get_code/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(st, {accounts, storage, code,
             accounts_file, storage_file, code_file}).

start_link(Cfg) ->
    Name = maps:get(name, Cfg, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Cfg, []).

%% Accounts: [{Hash32, AcctRLP}].
put_accounts(Pairs) -> put_accounts(?MODULE, Pairs).
put_accounts(Name, Pairs) -> gen_server:call(Name, {put_accounts, Pairs}).

%% {ok, AcctRLP} | not_found.
get_account(Hash) -> get_account(?MODULE, Hash).
get_account(Name, Hash) -> gen_server:call(Name, {get_account, Hash}).

%% {ok, [{Hash, RLP}], CompleteHint} for hashes in [Origin, Limit).
account_range(Origin, Limit, MaxBytes) ->
    account_range(?MODULE, Origin, Limit, MaxBytes).
account_range(Name, Origin, Limit, MaxBytes) ->
    gen_server:call(Name, {account_range, Origin, Limit, MaxBytes}).

%% Storage: AccountHash + [{SlotHash, SlotRLP}].
put_storage(Acct, Pairs) -> put_storage(?MODULE, Acct, Pairs).
put_storage(Name, Acct, Pairs) ->
    gen_server:call(Name, {put_storage, Acct, Pairs}).

get_storage(Acct, Slot) -> get_storage(?MODULE, Acct, Slot).
get_storage(Name, Acct, Slot) ->
    gen_server:call(Name, {get_storage, Acct, Slot}).

storage_range(Acct, Origin, Limit, MaxBytes) ->
    storage_range(?MODULE, Acct, Origin, Limit, MaxBytes).
storage_range(Name, Acct, Origin, Limit, MaxBytes) ->
    gen_server:call(Name, {storage_range, Acct, Origin, Limit, MaxBytes}).

put_code(CodeHash, Code) -> put_code(?MODULE, CodeHash, Code).
put_code(Name, CodeHash, Code) ->
    gen_server:call(Name, {put_code, CodeHash, Code}).

get_code(CodeHash) -> get_code(?MODULE, CodeHash).
get_code(Name, CodeHash) -> gen_server:call(Name, {get_code, CodeHash}).

init(Cfg) ->
    Dir = maps:get(dir, Cfg, "./data"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Prefix = atom_to_list(maps:get(name, Cfg, ?MODULE)) ++ "_",
    AT = list_to_atom(Prefix ++ "accounts"),
    ST = list_to_atom(Prefix ++ "storage"),
    CT = list_to_atom(Prefix ++ "code"),
    TabA = ets:new(AT, [ordered_set, {keypos, 1}]),
    TabS = ets:new(ST, [ordered_set, {keypos, 1}]),
    TabC = ets:new(CT, [set, {keypos, 1}]),
    {ok, _} = dets:open_file(TabA, [{file, filename:join(Dir, "state.accounts.dets")},
                                    {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(TabS, [{file, filename:join(Dir, "state.storage.dets")},
                                    {type, set}, {repair, force}]),
    {ok, _} = dets:open_file(TabC, [{file, filename:join(Dir, "state.code.dets")},
                                  {type, set}, {repair, force}]),
    _ = dets:to_ets(TabA, TabA),
    _ = dets:to_ets(TabS, TabS),
    _ = dets:to_ets(TabC, TabC),
    {ok, #st{accounts = TabA, storage = TabS, code = TabC,
             accounts_file = TabA, storage_file = TabS, code_file = TabC}}.

handle_call({put_accounts, Pairs}, _From, S) ->
    lists:foreach(fun({H, R}) when byte_size(H) =:= 32, is_binary(R) ->
        ets:insert(S#st.accounts, {H, R}),
        dets:insert(S#st.accounts_file, {H, R})
    end, Pairs),
    {reply, ok, S};
handle_call({get_account, Hash}, _From, S) ->
    case ets:lookup(S#st.accounts, Hash) of
        [{Hash, R}] -> {reply, {ok, R}, S};
        [] -> {reply, not_found, S}
    end;
handle_call({account_range, Origin, Limit, MaxBytes}, _From, S) ->
    {reply, {ok, range(S#st.accounts, Origin, Limit, MaxBytes)}, S};
handle_call({put_storage, Acct, Pairs}, _From, S) ->
    lists:foreach(fun({Slot, R}) when byte_size(Slot) =:= 32, is_binary(R) ->
        ets:insert(S#st.storage, {{Acct, Slot}, R}),
        dets:insert(S#st.storage_file, {{Acct, Slot}, R})
    end, Pairs),
    {reply, ok, S};
handle_call({get_storage, Acct, Slot}, _From, S) ->
    case ets:lookup(S#st.storage, {Acct, Slot}) of
        [{_, R}] -> {reply, {ok, R}, S};
        [] -> {reply, not_found, S}
    end;
handle_call({storage_range, Acct, Origin, Limit, MaxBytes}, _From, S) ->
    Match = [{{{Acct, '$1'}, '$2'}, [], ['$_']}],
    All = lists:sort(ets:select(S#st.storage, Match)),
    Items = [{Slot, R} || {{_, Slot}, R} <- All, Slot >= Origin, Slot < Limit],
    {reply, {ok, pack_range(Items, MaxBytes)}, S};
handle_call({put_code, H, Code}, _From, S)
  when byte_size(H) =:= 32, is_binary(Code) ->
    ets:insert(S#st.code, {H, Code}),
    dets:insert(S#st.code_file, {H, Code}),
    {reply, ok, S};
handle_call({get_code, H}, _From, S) ->
    case ets:lookup(S#st.code, H) of
        [{H, C}] -> {reply, {ok, C}, S};
        [] -> {reply, not_found, S}
    end;
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S) ->
    _ = (try dets:close(S#st.accounts_file) catch _:_ -> ok end),
    _ = (try dets:close(S#st.storage_file) catch _:_ -> ok end),
    _ = (try dets:close(S#st.code_file) catch _:_ -> ok end),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

%% Ordered range [Origin, Limit): up to MaxBytes of RLP payload.
range(Tab, Origin, Limit, MaxBytes) ->
    range_from(first_key(Tab, Origin), Tab, Origin, Limit,
               MaxBytes, 0, []).

first_key(Tab, <<>>) ->
    ets:first(Tab);
first_key(Tab, Origin) ->
    case ets:lookup(Tab, Origin) of
        [_] -> Origin;
        [] -> ets:next(Tab, Origin)
    end.

range_from('$end_of_table', _, _, _, _, _, Acc) ->
    lists:reverse(Acc);
range_from(Key, Tab, Origin, Limit, MaxBytes, Bytes, Acc)
  when Key >= Origin, Key < Limit ->
    [{Key, R}] = ets:lookup(Tab, Key),
    case Bytes + byte_size(R) > MaxBytes andalso Acc =/= [] of
        true ->
            lists:reverse(Acc);
        false ->
            range_from(ets:next(Tab, Key), Tab, Origin, Limit, MaxBytes,
                       Bytes + byte_size(R), [{Key, R} | Acc])
    end;
range_from(_, _, _, _, _, _, Acc) ->
    lists:reverse(Acc).

pack_range(Items, MaxBytes) ->
    pack_range(Items, MaxBytes, 0, []).

pack_range([], _, _, Acc) ->
    lists:reverse(Acc);
pack_range([{_, R} = I | Rest], MaxBytes, Bytes, Acc) ->
    case Bytes + byte_size(R) > MaxBytes andalso Acc =/= [] of
        true -> lists:reverse(Acc);
        false -> pack_range(Rest, MaxBytes, Bytes + byte_size(R), [I | Acc])
    end.
