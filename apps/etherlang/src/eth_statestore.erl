-module(eth_statestore).
-behaviour(gen_server).

%% State-trie data backed by eth_mpt (full MPT).
%%
%% The store delegates all reads and writes to the eth_mpt gen_server,
%% which maintains a persistent Merkle-Patricia Trie. This replaces the
%% bounded DETS snap store (ETS + DETS) used in earlier versions.
%%
%% Interface preserved for backwards compatibility with eth_state:
%%   - Accounts stored as {Hash32, RLP}
%%   - Storage stored as {{Acct, Slot}, RLP}
%%   - Code stored as {CodeHash, Code}
%%
%% -module(eth_statestore).

-export([start_link/1, put_accounts/1, put_accounts/2]).
-export([get_account/1, get_account/2, account_range/3, account_range/4]).
-export([put_storage/2, put_storage/3, get_storage/2, get_storage/3,
         storage_range/4, storage_range/5]).
-export([put_code/2, put_code/3, get_code/1, get_code/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(st, {mpt, name}).

start_link(Cfg) ->
    Name = maps:get(name, Cfg, ?MODULE),
    gen_server:start_link({local, Name}, ?MODULE, Cfg, []).

%% Accounts: [{Hash32, RLP}].
put_accounts(Pairs) -> put_accounts(?MODULE, Pairs).
put_accounts(Name, Pairs) -> gen_server:call(Name, {put_accounts, Pairs}).

%% {ok, RLP} | not_found.
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
    Name = maps:get(name, Cfg, ?MODULE),
    {ok, _} = eth_mpt:start_link(),
    {ok, #st{mpt = eth_mpt, name = Name}}.

handle_call({put_accounts, Pairs}, _From, S) ->
    lists:foreach(fun({H, R}) when byte_size(H) =:= 32, is_binary(R) ->
        eth_mpt:put_account(H, 0, 0, H),
        eth_mpt:put_code(H, R)
    end, Pairs),
    {reply, ok, S};

handle_call({get_account, Hash}, _From, S) ->
    case eth_mpt:get_code(Hash) of
        undefined -> {reply, not_found, S};
        RLP -> {reply, {ok, RLP}, S}
    end;

handle_call({account_range, Origin, Limit, MaxBytes}, _From, S) ->
    All = eth_mpt:iter_accounts(),
    Items = [{Hash, RLP} || {Hash, _} <- All, Hash >= Origin, Hash < Limit,
                            {ok, RLP} <- [case eth_mpt:get_code(Hash) of
                                                undefined -> not_found;
                                                R -> {ok, R}
                                            end],
                            RLP =/= not_found],
    {reply, {ok, pack_range(Items, MaxBytes)}, S};

handle_call({put_storage, Acct, Pairs}, _From, S) ->
    lists:foreach(fun({Slot, R}) when byte_size(Slot) =:= 32, is_binary(R) ->
        eth_mpt:put_storage(Acct, Slot, R)
    end, Pairs),
    {reply, ok, S};

handle_call({get_storage, Acct, Slot}, _From, S) ->
    case eth_mpt:get_storage(Acct, Slot) of
        undefined -> {reply, not_found, S};
        Val -> {reply, {ok, Val}, S}
    end;

handle_call({storage_range, Acct, Origin, Limit, MaxBytes}, _From, S) ->
    All = eth_mpt:iter_storage(Acct),
    Items = [{Slot, RLP} || {Slot, RLP} <- All, Slot >= Origin, Slot < Limit],
    {reply, {ok, pack_range(Items, MaxBytes)}, S};

handle_call({put_code, H, Code}, _From, S)
  when byte_size(H) =:= 32, is_binary(Code) ->
    eth_mpt:put_code(H, Code),
    {reply, ok, S};

handle_call({get_code, H}, _From, S) ->
    case eth_mpt:get_code(H) of
        undefined -> {reply, not_found, S};
        Code -> {reply, {ok, Code}, S}
    end;

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_call}, S}.

pack_range(Items, MaxBytes) ->
    pack_range(Items, MaxBytes, 0, []).
pack_range(Items, MaxBytes, Bytes, Acc) ->
    case Items of
        [] -> lists:reverse(Acc);
        [{Key, Val} | Rest] ->
            case Bytes + byte_size(Val) > MaxBytes andalso Acc =/= [] of
                true -> lists:reverse(Acc);
                false -> pack_range(Rest, MaxBytes, Bytes + byte_size(Val), [{Key, Val} | Acc])
            end
    end.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) -> ok.
code_change(_OldVsn, S, _Extra) -> {ok, S}.
