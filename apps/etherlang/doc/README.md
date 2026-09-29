# The comment corpus, and what the tools do with it

Three artefacts, and this file is the one that says how they relate. All output goes to
`doc/`, which is gitignored; this file is the only thing here that is source.

| command | what it makes | where |
|---|---|---|
| `make docs` | the **API reference**: every export, spec, type | `doc/index.html` |
| `make rationale` | the **comment corpus**: every `%%` block, with its adjacency | `doc/rationale/index.html` |
| `make edoc-preview` | what `make docs` *would* look like with `%% @doc` tags | `doc/edoc-preview/index.html` |

## The measurement that made the second one necessary

`edoc-1.5` on OTP 29 binds a comment to a function **only when the comment carries an
explicit `%% @doc` tag**. Plain `%%` prose is dropped, and it is dropped *silently*.

Established with a three-function control rather than assumed, because "EDoc ignores my
comments" has more than one possible cause:

| control | comment immediately above the head | result |
|---|---|---|
| `%% Alpha does a thing.` | yes | signature only |
| `%% @doc Gamma's documentation.` | yes | rendered |

So all **6,133 comment lines** across the 48 modules in `src` are absent from `make docs`
output. This is a property of the tool, not of the comments.

## `make rationale` — the corpus, and what it is not

**1,029 comment blocks over 6,133 lines, 48 modules.** Each is rendered in source order
with **what the source has on either side of it**, and nothing is inferred:

| label | blocks | means |
|---|---|---|
| `precedes` | 572 | the next line of code is the one after the block, and it is a function head |
| `follows` | 238 | the block sits inside a function body, so it is trailing rationale for that function |
| `banner` | 219 | blank lines on both sides: a section banner, or a block belonging to no single function |

**`precedes` is tested first, deliberately.** A comment between the end of one function
and the head of the next, with no blank line anywhere, satisfies *both* rules. Testing
`follows` first sent all of them to `follows` and the tool reported 148 `precedes` where
an independent count said 513 — the missing 365 were precisely the comments in edoc's own
canonical position for a docstring. Adjacency to a head is the more specific claim.

Parsed with `erl_scan:string/3` and `{return_comments, true}`, **not by reading lines**:
a line-based scan cannot tell `%%` inside a string from a comment, and this codebase has
plenty of both. `erl_scan` is the compiler's own front end, so `"%% not a comment"` is
correctly not a comment.

## `make edoc-preview` — the argument against doing it for real

This is the one that settles the question, and it is a tool rather than a claim.
`tools/edoc_preview.escript` copies `src` into a scratch directory, inserts `%% @doc `,
runs edoc over the copy, and reports what happened. **`apps/etherlang/src` is never
opened for writing.**

By default it tags only the 572 `precedes` blocks — the ones a person would agree are
about that function. The result:

> **edoc wrote 35 pages of 48.** Thirteen modules cannot be documented at all.

Two content causes, both from ordinary prose:

* **`<` in a comment.** `eth_snappy` has `(<= 60 bytes each …)`; `eth_evm` has
  `<0:256>`. edoc passes a docstring through an XML writer, and `<` opens a tag, so it
  dies with `{invalid_name, "= 60 b"}` — a name that is the middle of an English
  sentence. **12 of the 13 failures contain a `<`; 32 of the 35 successes contain none.**
* **An unbalanced `'`.** edoc's markup treats `'` as a quote delimiter, so an ordinary
  English possessive breaks it: `eth_state` has `the consensus runner is that caller`
  and, three lines up, `client's`, and the tool answers `` `-quote ended unexpectedly ``.
  **945 comment lines across 32 modules have an odd apostrophe count.**

So the mechanical conversion is not merely inelegant here — **it fails**, and it fails on
the notation this codebase is made of: opcode listings, `x < y` comparisons, and
`EIP-2929's`. Escaping all of it is a source change that damages the comments' readability
to satisfy a tool.

The classification in the preview and the one in the rationale index are the same code
for the same reason: if the two disagreed, a comparison between their output would be
confounded by the classifier rather than by the thing being compared. They agree exactly
— 572 / 238 / 219 over 1,029 blocks, from two independently written tools.

## Where the documentation actually is

| file | what it holds |
|---|---|
| `AGENTS.md` | How the node is built and the rules it has had to learn. §10 is the open/closed ledger, §10a the traps. |
| `TASKS.md` | The queue, and the measurement behind every claim in it. |
| `README.md` | Feature status, honesty notes, the compatibility table. |
| `docs/YELLOW_PAPER.md` | The system model, the trust assumptions, what the node does *not* claim. |
| `apps/etherlang/test/vectors/eest/PROVENANCE.md` | Where the conformance fixtures came from, and how to run the whole corpus. |

## The application overview page is empty, and that is also the tool

edoc's built-in HTML layout takes application-level prose from a **module** whose name
matches the application; it never reads an `overview.edoc` file, and the `app_default`
option is only a base URI for cross-references (`edoc_refs:join_uri/2`). This application
is `etherlang` and there is no `etherlang` module.

Adding an otherwise-empty module that exists only to carry a docstring was considered and
rejected: `AGENTS.md` §11 is a catalogue of dead code, and a module with no callers is
precisely what it is about.
