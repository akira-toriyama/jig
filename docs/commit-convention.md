# Commit convention & versioning

This repo commits with **gitmoji + Conventional Commits**; from the messages
[git-cliff](https://git-cliff.org) computes semver and the release notes.

## Format

```
<gitmoji> <type>(<scope>)<!>: <subject>

<body, optional>

<footer, optional / BREAKING CHANGE: ...>
```

- `<gitmoji>` … exactly one leading gitmoji in the `:sparkles:` **text form**
  (grep-friendly; not the emoji glyph). e.g. `:bug:`.
- `<type>` … Conventional Commits type (`feat` `fix` `perf` `refactor` `docs`
  `test` `build` `ci` `chore` `style` `revert`). **semver is decided by this.**
- `<scope>` … optional: `json` `parser` `eval` `diag` `args` `cli` `compat`
  `install` `ci` `packaging`.
- `!` … breaking change. Or a `BREAKING CHANGE: <desc>` footer.
- `<subject>` … imperative, concise. English or Japanese (match history).

### Examples

```
:sparkles: feat(eval): implement object construction {a: .b}
:bug: fix(json): reject unpaired UTF-16 surrogates with position
:zap: perf(parser): fast path for ASCII identifiers
:boom: feat(cli)!: change default output to compact
:memo: docs(roadmap): record ?? vs // operator decision
:wrench: chore: tidy .gitignore
:green_heart: ci: pin macos-15 runner
```

## semver mapping

| Change | Type / marker | Version |
|---|---|---|
| Breaking change | `<type>!` / `BREAKING CHANGE:` | **major** |
| New feature | `feat` | **minor** |
| Bug fix / perf | `fix` / `perf` | **patch** |
| Everything else (`docs` `ci` `chore` `style` `test` `refactor` `build`) | — | **no bump** |

The **type is authoritative** for semver; gitmoji is for readability and
changelog grouping. Bot commits are excluded from versioning and the
changelog (see [cliff.toml](../cliff.toml) `commit_parsers`).

## Release flow

Releases are automated by [.github/workflows/release.yml](../.github/workflows/release.yml)
(rolling-draft model):

1. Merge `feat:`/`fix:`/`perf:` to `main`. git-cliff computes the next
   version and the workflow creates/updates a single **draft** GitHub Release
   with the built `jig` binary attached. No tag yet.
2. Review the draft; **Publish** it in the GitHub UI — GitHub creates the tag
   (`vX.Y.Z`) on the target commit at publish time. Keep
   `JigVersion.current` (Sources/JigCore/Version.swift) in sync with the
   version you publish.
3. The publish event triggers `update-tap.yml`, which surgically bumps the
   `url` and `sha256` in `akira-toriyama/homebrew-tap`'s `Formula/jig.rb`.

`workflow_dispatch` with `dry_run=true` is a full preview (no draft, no
version consumed). Non-bumping-only changes ⇒ the workflow no-ops.

## Local hook (optional, low-dependency)

No Node required. Enable the bundled shell hook:

```sh
git config core.hooksPath scripts/hooks
```

`commit-msg` validates the gitmoji + Conventional form. CI validates the
same on every PR via [.github/workflows/commit-lint.yml](../.github/workflows/commit-lint.yml).
