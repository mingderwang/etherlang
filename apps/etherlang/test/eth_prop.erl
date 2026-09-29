%% -*- erlang -*-
%% A property-test harness, in plain Erlang and eunit, with no dependency added.
%%
%% Three things it does that a loop of `?assertEqual`s does not, and all three exist
%% because of a way a property test fails *silently*:
%%
%%   1. **The seed is reported on every failure.** A property test that finds a
%%      counterexample once and cannot reproduce it is not a test, it is a rumour. The
%%      seed is a constant unless `ETH_PROP_SEED` says otherwise, so a green run is green
%%      by default and reproducible by default, and a red one names the seed to re-run
%%      with.
%%
%%   2. **The generator is biased towards boundaries.** A uniform random 256-bit word is
%%      essentially never 0, 1, 2^255, 2^256-1 or a power of two, and those are where word
%%      arithmetic breaks. A purely uniform generator will pass every property here
%%      forever while testing nothing near the interesting cases. `word/0` mixes uniform
%%      values with a fixed set of adversarial ones for exactly this reason.
%%
%%   3. **The number of cases is fixed and reported on failure**, so "it passed" is a
%%      statement about a stated number of inputs rather than an unbounded shrug.
%%
%% What it deliberately does not do: **shrink a counterexample.** A minimal case is
%% genuinely more useful than the first one found, and shrinking is more machinery than
%% this repository's other test infrastructure. Until it exists the honest thing is to
%% say so, rather than to imply the counterexample is minimal.
%%
%% On the RNG: this uses `rand:seed/2` and the **process-local** `rand:uniform/1`, not
%% `rand:uniform_s/2` threaded by hand. `uniform_s/2` returns `{Value, NewState}' and
%% advances an explicit state, so every generator would have to thread it -- and getting
%% that wrong is silent in the worst way, because a generator that ignores the new state
%% returns the *same* value forever and the property is tested on one input, 400 times,
%% while reporting 400 cases. The process-local API cannot be got wrong that way, and
%% eunit runs each test in its own process, so the per-test seed is exact.
-module(eth_prop).

-export([for_all/3, for_all/4, word/0, shift/0, small/0, modulus/0, seed/0,
         interesting_words/0, interesting_shifts/0]).

-define(DEFAULT_SEED, {20, 26, 2026}).

%% ---------------------------------------------------------------------------
%% Entry point

%% `Gen' is `fun(Index) -> Arguments' and `Property' is
%% `fun(Arguments) -> true | {false, Why}' -- or anything else that is not `true`, so a
%% property cannot pass by accident by returning something truthy.
%%
%% **Return `{false, GotVsWant}` rather than `false`.** A property that answers a bare
%% `false` reports the inputs and nothing else, and reproducing the failure then means
%% re-deriving what the property was comparing. One of these did exactly that: a signextend
%% cross-check reported a counterexample that, run by hand against the module, *passed* --
%% so either the report was wrong or the arithmetic was, and there was no way to tell which
%% from the message. A property that returns what it got and what it wanted settles it in
%% the failure itself.
for_all(Name, Cases, {Gen, Property}) ->
    for_all(Name, Cases, Gen, Property).

for_all(Name, Cases, Gen, Property) ->
    Seed = seed(),
    %% Seeds the **calling process's** rand state. `rand:seed/2` is process-local by
    %% design, which is what makes a per-test seed exact here.
    rand:seed(exsplus, Seed),
    first_failure(Name, Cases, Gen, Property, Seed).

first_failure(_Name, 0, _Gen, _Property, _Seed) ->
    ok;
first_failure(Name, N, Gen, Property, Seed) ->
    Index = N,
    Args = Gen(Index),
    case Property(Args) of
        true -> first_failure(Name, N - 1, Gen, Property, Seed);
        %% `cases' is the number of cases still to run, **not** an iteration counter, so it
        %% reads 400 for a failure on the first case. That is deliberate -- it says "this
        %% failed immediately", which an iteration number would hide -- but it means a
        %% reader must not treat it as "it took 400 tries to find this".
        Why -> erlang:error({property_failed, Name,
                             #{seed => Seed,
                               cases_remaining => Index,
                               inputs => Args,
                               why => Why}})
    end.

seed() ->
    case os:getenv("ETH_PROP_SEED") of
        false -> ?DEFAULT_SEED;
        "" -> ?DEFAULT_SEED;
        S -> list_to_integer(S)
    end.

%% ---------------------------------------------------------------------------
%% Generators

%% The adversarial values, named rather than inlined at each use, because the point of
%% listing them is that they are a *set somebody chose*. MIN/MAX and the powers of two are
%% where two's-complement word arithmetic goes wrong; 0 and 1 are where the degenerate
%% cases are; the values either side of 2^255 are where sign handling goes wrong.
interesting_words() ->
    [0, 1, 2, 3, 7, 8, 31, 32, 255, 256, 257,
     (1 bsl 8) - 1, 1 bsl 8, (1 bsl 16) - 1, 1 bsl 16,
     (1 bsl 32) - 1, 1 bsl 32, (1 bsl 128) - 1, 1 bsl 128,
     (1 bsl 255) - 1, 1 bsl 255, (1 bsl 255) + 1,
     (1 bsl 256) - 1].

interesting_shifts() ->
    [0, 1, 7, 8, 31, 32, 63, 64, 127, 128, 254, 255, 256, 257, 1000].

word() ->
    case rand:uniform(3) of
        1 -> pick(interesting_words());
        2 -> small();
        3 -> uniform_word()
    end.

%% 32 random bytes, so a uniform value really does span all 256 bits. Built from bytes
%% rather than `rand:uniform(1 bsl 256)' because that range is larger than the algorithm's
%% own state and silently loses entropy in the high bits.
uniform_word() ->
    <<W:256>> = << <<(rand:uniform(256) - 1):8>> || _ <- lists:seq(1, 32) >>,
    W.

%% Shift amounts: a uniform draw over 0..256 would hit 0 about one time in 257, and
%% `shl(X, 0)` is exactly the case worth always testing.
shift() ->
    case rand:uniform(3) of
        1 -> pick(interesting_shifts());
        2 -> 0;
        3 -> rand:uniform(257) - 1
    end.

small() ->
    rand:uniform(65536) - 1.

%% A modulus, with 0 included on purpose: `addmod/3` and `mulmod/3` define modulus 0 as 0,
%% and that is the EVM's answer rather than an accident to be excluded from the test.
modulus() ->
    case rand:uniform(3) of
        1 -> pick([1, 2, 3, 7, 255, 256, 257, 1 bsl 128, (1 bsl 256) - 1]);
        2 -> 0;
        3 -> small()
    end.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
