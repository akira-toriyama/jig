# jig

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-early%20WIP-red)

**English** · [日本語](README.ja.md)

A **jq-compatible JSON processor with humane errors**. jig runs your jq
filters and keeps jq's semantics — but when something goes wrong, it tells
you *where* in the filter, *what* it found, and *what to try next*:

```console
$ echo '{}' | jig '.items[]'
jig: error: cannot iterate over null (null) (input #1)
  .items[]
        ^^
  hint: use .[]? to skip non-iterable inputs, or // [] to default missing data
```

(Compare jq: `jq: error (at <stdin>:0): Cannot iterate over null (null)`.)

A *jig* is the workshop fixture that holds the stock and guides the cutting
tool — which is what a query program does to JSON. Part of the
[atelier](https://github.com/akira-toriyama/atelier) family of Swift tools.

> ⚠️ **Early WIP.** jig currently implements a small core of the jq language
> (see *Status*). The foundation — streams, diagnostics, number-literal
> preservation, jq exit codes — is in place; the language surface is growing
> toward full compatibility ([roadmap](docs/jq-compat.md)).

## Why another jq?

jq is brilliant and jig intends to stay compatible with it
([compatibility contract](docs/jq-compat.md)). But some long-standing pain
points deserve fixing at the implementation level:

- **Diagnostics.** Every jig error carries a source span (caret under your
  filter), jq-vocabulary type names, and a hint. No bison-speak, no
  position-less runtime errors. Smart quotes pasted from a chat app and
  shell-swallowed quoting are detected and explained.
- **Numbers survive.** `12345678901234567890` round-trips intact (jq 1.7
  literal preservation, the jq ≤1.6 silent-corruption case is a regression
  test here).
- **No crashes.** The hand-written parsers must produce a value or a
  friendly error for *any* byte sequence — never an assert.
- **Quiet and fast by default.** Zero extra I/O on the happy path; startup
  time is a tracked budget, not an accident (jq 1.6's 10× startup
  regression is the cautionary tale).

jig is **dual-mode**: the default **jq mode** matches jq 1.7's observable
behavior, so `alias jq=jig` keeps your scripts working. An opt-in **humane
mode** (`--humane`, or `# jig:humane` at the top of a filter) turns on the
saner-but-incompatible semantics — e.g. `//` stops treating `false` as
missing, and iterating `null` yields nothing instead of erroring. Breaking
changes only ever live behind that switch, and each one is enumerated in
[docs/jq-compat.md](docs/jq-compat.md). The `??` nullish operator is additive
and available in both modes.

## Usage

```sh
curl -s https://api.example.com/users | jig '.[] | .name'   # from a pipe
jig -r '.maintainers[].name' sample/foo.json                # from a file
cat sample/foo.json | jig -c '.tags' -                      # `-` = stdin
```

### Try it

The repo ships two sample documents under [`sample/`](sample/):

```console
$ jig -r '.maintainers[] | .name' sample/foo.json
ann
bob
cy

$ jig -c '.maintainers | map(select(.active))' sample/foo.json
[{"name":"ann","active":true,"commits":128},{"name":"cy","active":true,"commits":7}]

$ jig '.maintainers | map(.commits) | add' sample/foo.json
177

$ jig '.repo.big_id' sample/foo.json          # 64-bit id, preserved exactly
12345678901234567890

# // drops false+null; ?? (nullish) keeps false — compare on sample/bar.json
$ jig -c 'map(.shipped // "pending")' sample/bar.json
["pending",true,"pending"]
$ jig -c 'map(.shipped ?? "pending")' sample/bar.json
["pending",true,false]

$ jig explain '.maintainers[] | .name'        # plain-language + JS analogy
  …
  ≈ JS: input.maintainers.map(x => x.name)
```

### Currently supported (v0)

`.` `.foo` `.foo?` `.[0]` `.[-1]` `.[]` `.[]?` `|` `,` `( … )` `# comments`,
scalar literals (`42` `"s"` `true` `false` `null`), `a // b`, `a ?? b`, and
builtins `length keys keys_unsorted type not reverse add empty map(f)
select(f) has(k)` (ECMAScript aliases `typeof`, `filter`). Subcommands
`jig explain` / `jig check`. Full surface and roadmap:
[docs/jq-compat.md](docs/jq-compat.md).

## Input / Output

jig is a Unix filter, aligned with [clig.dev](https://clig.dev):

- **Input** — JSON from **stdin**, from **file arguments**, or from `-`
  (stdin). One source may hold a **stream** of whitespace-separated documents
  (including NDJSON); each is filtered in turn.
- **stdout** — the JSON results, one value per line. 2-space pretty by
  default; `-c` compact; `-r` emits top-level strings raw (no quotes).
- **stderr** — diagnostics only (errors, hints, `JIG_DEBUG` traces), so they
  never pollute the data on stdout.
- **Exit codes** (mirroring jq): `0` ok · `2` usage / unreadable or malformed
  input · `3` filter compile error · `5` a runtime error occurred while
  filtering.
- With **no piped input** on an interactive terminal, jig prints a hint
  instead of hanging — pipe data, pass a file, or use `-n`.

## Install

From source (macOS 13+, Swift 6 toolchain):

```sh
git clone https://github.com/akira-toriyama/jig.git
cd jig
./install.sh          # builds and places ~/.local/bin/jig
```

Homebrew (`brew install akira-toriyama/tap/jig`) will be available once the
first release is published.

## Development

```sh
./build.sh            # swift build -c release → bin/jig (codesigned)
./run.sh              # build + demo filters with JIG_DEBUG=1 tracing
swift test            # needs full Xcode (XCTest); CI runs this on every PR
```

Verbose tracing is env-var-only (family convention): `JIG_DEBUG=1 jig … `
writes a trace to stderr and `/tmp/jig.log`. There is no `--debug` flag.

See [CLAUDE.md](CLAUDE.md) for architecture and constraints,
[docs/glossary.md](docs/glossary.md) for canonical terminology,
[docs/commit-convention.md](docs/commit-convention.md) for the commit/release
flow, and [docs/jq-compat.md](docs/jq-compat.md) for the compatibility
policy.

## Family

jig follows the [atelier](https://github.com/akira-toriyama/atelier) house
style — SwiftPM hexagonal layers, gitmoji + Conventional Commits, git-cliff
rolling-draft releases, Homebrew tap distribution — alongside
[chord](https://github.com/akira-toriyama/chord),
[facet](https://github.com/akira-toriyama/facet),
[glance](https://github.com/akira-toriyama/glance) (try
`… | jig '.text' -r | glance --markdown`),
[perch](https://github.com/akira-toriyama/perch),
[sill](https://github.com/akira-toriyama/sill), and
[wand](https://github.com/akira-toriyama/wand).

## License

[MIT](LICENSE)
