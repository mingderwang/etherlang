# Generated API reference

`make docs` runs `edoc` over the 48 modules in `apps/etherlang/src` and writes HTML
here. **This directory is a build artifact and is gitignored** (see `.gitignore`); the
only file here that is source is nothing — regenerate with `make docs`.

## What is in it

Every exported function with its spec, its argument types and its return type, for all
48 modules. That is a real, complete API surface index and it is what this is for.

## What is *not* in it, and why

**None of this repository's prose.** There are 6,035 `%%` comment lines in
`apps/etherlang/src` and not one of them appears in the generated pages.

That is a property of `edoc-1.5` on OTP 29, not an omission here. It binds a comment to
a function **only when the comment carries an explicit `%% @doc` tag**, and plain `%%`
prose is dropped **silently** — verified with a three-function control module where the
canonical arrangement (comment immediately above the function head, no blank line)
produced a signature and nothing else. This tree has:

| | count |
|---|---|
| function heads with a `%%` block immediately above | 513 |
| …of which carry `%% @doc` | **0** |
| heads with a `%%` block separated by a blank line | 90 |

So the gap is not effort. What is in those comments is mostly **rationale** — what an EIP
says, what this node used to do, what the symptom was — and a good deal of it is
deliberately placed *after* the function it explains, or spans several functions as a
section banner. Mechanically prefixing `@doc` would turn a design-decision essay into
the docstring of whichever function happened to follow it, which is the same mistake as
the three tests in this repository that recorded a defect as a requirement.

## Where the documentation actually is

| file | what it holds |
|---|---|
| `AGENTS.md` | How the node is built, and the rules it has had to learn. §10 is the open/closed ledger; §10a the traps. |
| `TASKS.md` | The queue, and the measurement behind every claim in it. |
| `README.md` | Feature status, honesty notes, the compatibility table. |
| `docs/YELLOW_PAPER.md` | The system model, the trust assumptions, and what the node does *not* claim. |
| `apps/etherlang/test/vectors/eest/PROVENANCE.md` | Where the conformance fixtures came from and how to run the whole corpus. |

## The app overview page is empty, and that is also the tool

`edoc`'s built-in HTML layout takes the application-level prose from a **module** whose
name matches the application — it never reads an `overview.edoc` file, and the
`app_default` option is only a base URI for cross-references. This application is
`etherlang` and there is no `etherlang` module.

Creating an otherwise-empty module that exists only to carry a docstring was considered
and rejected: `AGENTS.md` §11 is a catalogue of dead code, and a module with no
callers is precisely what it is about. The prose is in the files listed above instead,
and pointing at them is more useful than a page that repeats the module list.
