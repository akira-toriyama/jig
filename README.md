# jig

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-early%20WIP-red)

**English** · [日本語](README.ja.md)

An **ergonomic JSON processor with humane diagnostics**. jig speaks a small,
jq-inspired filter language — but when something goes wrong, it tells you
*where* in the filter, *what* it found, and *what to try next*:

```console
$ echo '5' | jig '.name'
jig: error: cannot index number with "name" (input #1)
  .name
  ^^^^^
  hint: use .name? to skip inputs where this isn't an object
```

(jq reports `Cannot index number with "name"` too — but with no caret showing
*where* in your filter it went wrong.)

A *jig* is the workshop fixture that holds the stock and guides the cutting
tool — which is what a query program does to JSON. Part of the
[atelier](https://github.com/akira-toriyama/atelier) family of Swift tools.

> ⚠️ **Early WIP — direction shift (2026-06-13).** jig is becoming **the
> ergonomic JSON CLI**: jq-inspired syntax (a Unix-pure `|` pipe), a
> lodash/es-toolkit-flavored builtin vocabulary, and humane diagnostics. It no
> longer chases byte-for-byte jq compatibility (that's jq's / gojq's / jaq's
> job). What's implemented today is a small jq-like core (see *Currently
> supported*); where jig is heading and why is in the
> **[roadmap](docs/roadmap.md)**.

## Why another jq?

jq is brilliant, and jig borrows its best idea — *JSON + a Unix pipe* — without
chasing byte-for-byte compatibility (need that? reach for jq / gojq / jaq).
Several long-standing pain points are worth fixing at the design level:

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

jig has **one semantics** — there is no mode switch. It keeps the jq spellings
that have no better idiom (`//` falls back on `false`/`null`; `?` for optional
access) and adopts a saner default where one clearly exists: iterating `null`
yields nothing instead of erroring (consistent with how `null` already flows
through `.foo` / `.[N]`), and the ECMAScript `??` gives nullish-only fallback
(drops `null`, keeps `false`). Where the language is headed next is in the
**[roadmap](docs/roadmap.md)**.

## Usage

```sh
curl -s https://api.example.com/users | jig '.[] | .name'   # from a pipe
jig -r '.maintainers[].name' sample/project.json                # from a file
cat sample/project.json | jig -c '.tags' -                      # `-` = stdin
```

### Try it

The repo ships two sample documents under [`sample/`](sample/):

```console
$ jig -r '.maintainers[] | .name' sample/project.json
ann
bob
cy

$ jig -c '.maintainers | map(filter(.active))' sample/project.json
[{"name":"ann","active":true,"commits":128},{"name":"cy","active":true,"commits":7}]

$ jig '.maintainers | map(.commits) | sum' sample/project.json
177

$ jig '.repo.big_id' sample/project.json          # 64-bit id, preserved exactly
12345678901234567890

# // drops false+null; ?? (nullish) keeps false — compare on sample/orders.json
$ jig -c 'map(.shipped // "pending")' sample/orders.json
["pending",true,"pending"]
$ jig -c 'map(.shipped ?? "pending")' sample/orders.json
["pending",true,false]

$ jig -r '.maintainers[] | "\(.name) → \(.commits) commits"' sample/project.json
ann → 128 commits
bob → 42 commits
cy → 7 commits

$ jig explain '.maintainers[] | .name'        # plain-language + JS analogy
  …
  ≈ JS: input.maintainers.map(x => x.name)
```

### Currently supported (v0)

`.` `.foo` `.foo?` `.[0]` `.[-1]` `.[a:b]` (slice) `.[]` `.[]?` `|` `,` `( … )`
`# comments`, scalar literals (`42` `"s"` `true` `false` `null`), object / array
construction (`{a: .b}`, `{user}` shorthand, `{(.k): .v}` computed keys, `[.x, .y]`),
string interpolation `"a\(.x)b"` (with the additive ECMAScript spelling
`"a${.x}b"`), `a // b`, `a ?? b`,
arithmetic `+ - * / %` (incl. `"s"*n`, `arr-arr`, `obj+obj` merge / `obj*obj`
deep-merge, `str/str` split), comparison `== != < <= > >=` (jq's cross-type
total order), logical `and` / `or`, unary minus `-x`, and builtins
`length keys keys_unsorted typeof not reverse sum empty map(f) filter(f) has(k)`
plus the Wave 1 composition + aggregation set
`range(n) groupBy(f) mapValues(f) orderBy(f) toPairs fromPairs min max minBy(f)
maxBy(f) uniq uniqBy(f) countBy(f) keyBy(f) sumBy(f)`
(descending is `orderBy(f) | reverse`; `uniq` keeps order where jq's `unique`
sorts). jq aliases `type` / `add` / `select` / `map_values` / `min_by` / `max_by`
are accepted. Subcommands `jig explain` /
`jig check`. Full surface and roadmap: [docs/roadmap.md](docs/roadmap.md).

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
[docs/principles.md](docs/principles.md) for the language-design principles
(Unix-native, comma is always a stream, compose small, diagnostics are the product),
[docs/roadmap.md](docs/roadmap.md) for direction and the builtin vocabulary,
[docs/glossary.md](docs/glossary.md) for canonical terminology,
[docs/commit-convention.md](docs/commit-convention.md) for the commit/release
flow, and [docs/jq-compat.md](docs/jq-compat.md) for the **superseded**
jq-compat notes (historical reference).

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
