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

What jig will **not** do: break jq programs. Language extensions are
additive-only (e.g. a planned `??` that — unlike `//` — doesn't treat
`false` as missing).

## Usage

```sh
curl -s https://api.example.com/users | jig '.[] | .name'
jig -r '.items[0].id' data.json
echo '{"a":{"b":[1,2,3]}}' | jig -c '.a.b[]'
```

Currently supported filter syntax (v0): `.` `.foo` `.foo?` `.[0]` `.[-1]`
`.[]` `.[]?` `|` `,` `( … )` — plus `-c` / `-r` / `-n`, multi-document input
streams (NDJSON), and jq-mirroring exit codes (0 / 2 usage / 3 compile /
5 runtime). Full surface and roadmap: [docs/jq-compat.md](docs/jq-compat.md).

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
