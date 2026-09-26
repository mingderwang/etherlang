%% The execution payload structure.
%%
%% This lives in a header rather than inside eth_block because a record defined
%% in a module is invisible to everything else: without it, no caller can read a
%% finalized block's fields, and the only way to construct a block with a chosen
%% timestamp or transaction list is to route through an exported setter per
%% field. That is enough to make the record an accidental private detail, which
%% it is not -- it is the primary data structure of the execution layer, and
%% every JSON-RPC handler that answers a block query needs it.
%%
%% The field order matches the post-Merge header, with the fields the header
%% itself does not carry (receipts, logs, the withdrawals list) appended in the
%% order the header-building code reads them.

-record(block, {
    parent_hash :: binary(),
    number :: integer(),
    timestamp :: integer(),
    miner :: binary(),
    difficulty :: integer(),
    gas_limit :: integer(),
    gas_used :: integer(),
    transactions :: [map()],
    receipts :: [map()],
    logs :: [map()],
    logs_bloom :: binary(),
    state_root :: binary(),
    receipts_root :: binary(),
    transactions_root :: binary(),
    base_fee_per_gas :: integer() | undefined,
    blob_gas_used :: integer(),
    excess_blob_gas :: integer(),
    withdrawals :: [map()],
    withdrawals_root :: binary(),
    %% EIP-4788. `undefined' means the field is absent (pre-Cancun); the
    %% all-zero word means present but carrying the genesis placeholder, which
    %% must not trigger the system call. The two are different and must not be
    %% conflated.
    parent_beacon_block_root :: binary() | undefined,
    extra_data :: binary(),
    nonce :: binary(),
    mix_hash :: binary(),
    sha3_uncles :: binary()
}).
