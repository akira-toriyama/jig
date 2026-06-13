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

## semantics review

- [ ] 意味論を一つに保っている（dual-mode / jq 互換契約は無い）。意味論を
      変える場合は [docs/roadmap.md](../blob/main/docs/roadmap.md) に **同 PR で**
      反映し、理由を本文に書く（破壊的変更はロードマップに沿って可）
- [ ] 語彙は es-toolkit 正典（jq 名は alias 受理のみ・docs/explain は正典形）
- [ ] 新しいエラーは span + hint を持つ（bare throw を増やしていない）

## Glossary review

- [ ] このコード変更で新規 domain term を導入していない（した場合は
      [docs/glossary.md](../blob/main/docs/glossary.md) を **同 PR で** 更新済）
- [ ] 既存の term を rename / 意味変更していない（した場合は
      `docs/glossary.md` を同期、旧名は entry の **`Don't call it:`** 欄へ追加済）

## Notes for reviewers
<!-- anything subtle: stream ordering, literal-preservation edge, layer crossing, … -->
