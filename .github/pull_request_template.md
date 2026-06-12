<!--
Title: gitmoji + Conventional Commits (see docs/commit-convention.md):
  :sparkles: feat(eval): implement object construction

If this is a single-commit PR, squashing into main will use the
commit message as the PR title — keep them in sync.
-->

## What this changes
<!-- one paragraph for humans -->

## Why
<!-- the constraint, bug, or feature request driving it -->

## Test plan

- [ ] `swift build` clean (local bar — XCTest needs full Xcode, CI runs `swift test`)
- [ ] added/updated tests in `Tests/JigCoreTests/` for the change
- [ ] smoke: `printf '<json>' | ./bin/jig '<filter>'` exercises the change
- [ ] (if user-facing) updated `README.md` AND `README.ja.md`
- [ ] (if a new constraint) added a "Non-obvious constraints" line in `CLAUDE.md`

## jq compatibility review

- [ ] 既存の jq プログラムの stdout / exit code を変えていない
      （変える場合は [docs/jq-compat.md](../blob/main/docs/jq-compat.md) の
      契約に照らして **同 PR で** 方針を更新し、理由を本文に書く）
- [ ] 新しいエラーは span + hint を持つ（bare throw を増やしていない）

## Glossary review

- [ ] このコード変更で新規 domain term を導入していない（した場合は
      [docs/glossary.md](../blob/main/docs/glossary.md) を **同 PR で** 更新済）
- [ ] 既存の term を rename / 意味変更していない（した場合は
      `docs/glossary.md` を同期、旧名は entry の **`Don't call it:`** 欄へ追加済）

## Notes for reviewers
<!-- anything subtle: stream ordering, literal-preservation edge, layer crossing, … -->
