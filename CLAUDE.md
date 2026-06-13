# CLAUDE.md

このリポジトリで作業する Claude / エージェント向けの構造・制約・流儀。
人間の README は [README.md](README.md) / [README.ja.md](README.ja.md)。

## 用語

UI / コード上の呼び名は [`docs/glossary.md`](docs/glossary.md) に従う —
正規名（`filter`, `generator semantics`, `literal preservation`,
`JigValue`, `diagnostic`, `optional marker`, `JIG_DEBUG`, …）のみを使い、
`Don't call it:` 側の同義語は使わない。用語の追加・改名はコード変更と
**同一 PR で** glossary へ反映する。

## What this is

**jig** = 人に優しい **JSON 操作 CLI**。**方向性の正本は
[docs/roadmap.md](docs/roadmap.md)** — まずそれを読む。

> ⭐ **2026-06-13 方針転換**: jig は jq の**完全互換を追わない**（厳密互換は
> jq/gojq/jaq の仕事）。モットー = **JSON を CLI から操作しやすく**。jq からは
> 「JSON + CLI」の概念だけ貰い、**jq 負債ゼロ**、lodash/es-toolkit のエルゴ
> ノミクスと humane 診断で最良の体験を作る。互換は「ほどよくカバー + 差分を
> crisp に列挙 + 堅い docs/テスト」。**破壊的変更/リファクタ OK**。テストは
> 「jq とバイト一致」でなく「**jig 自身の仕様への golden**」。
> 以前の「jq 互換契約 / dual-mode / `alias jq=jig`」記述（本ファイル下部や
> [docs/jq-compat.md](docs/jq-compat.md)）は **SUPERSEDED** — jq-compat.md は
> 差分カタログ・診断哲学の**参考資料**として残す。

**言語モデル（確定, roadmap §2）**: 一つの `|`（Unix 純パイプ＝現エンジンの
`.pipe`）・暗黙トピック `.`・builtin 引数は素のフィルタ（`map(.name)`）・jq
generator stream 維持・**JS は文法でなく“名前”で入れる**（lodash/es-toolkit
名の alias は可逆、`jig fmt`/`explain --canonical` が正典 `|` 形へ正規化）。
`|>`/メソッド鎖/アローは js-like 最下位ゆえ後回し（roadmap §5）。

### 設計ヒューリスティック（実装に迷ったら — roadmap §7）

1. **歴史で測る（普遍性=価値）**: unix と js の歴史を比べれば分かる。長く普遍
   なものほど価値が高い。CLI は今でも**原点にして頂点**。迷ったら長命で普遍な
   側（Unix のパイプ・テキストストリーム・小さく鋭い道具）を採る。
2. **AI 操作前提で予測可能に**: Claude Code 等の AI が jig を操作することは
   十分ありえる。**AI の理解しやすさ・予測しやすさを最優先**（一つの明白な道・
   明示 > 暗黙・良いエラーで復帰可能）。

**重み付けの正本**: Unix 美学 > Claude フレンドリー > 予測しやすさ > js-like。

### 作業原則（リレー — roadmap §6）

1 セッションでの完結を強制しない・**リレー形式**で次へ渡す・**できない所を
暗黙にしない**（未達/既知バグ/保留は roadmap・PR・メモリに明示）・ドキュメント
とテストを充実（lodash/es-toolkit 参照、長い docs は `<details>` 折りたたみ）。

```
curl -s https://api.example.com/users | jig '.[] | .name'
```

設計の核は「**humane diagnostics**」: すべてのエラーが span（プログラム内
位置）+ jq 語彙の型名 + hint を持つ。`unexpected INVALID_CHARACTER,
expecting $end` のような bison 語を出したら負け。

名前の由来: 治具 (jig) — 工房 (atelier) で素材を固定し刃の通り道を導く
道具。query program が JSON に対してやることそのもの。

## Architecture (SwiftPM 2-layer)

facet / chord / glance / perch と同じヘキサゴナル分割 — ただし pure
stdin/stdout CLI なので **AppKit adapter 層が無い**（JigApp が I/O adapter
を兼ねる）:

```
Sources/
  JigCore/             pure logic。JSON model (JSON.swift: JigValue/JigNumber)
                       / JSONParser / JSONWriter / Filter AST + FilterParser /
                       Evaluator / Args / Diagnostics / Version。
                       依存ゼロ・import Foundation 禁止 (例外: Log.swift)。
                       XCTest で単体検証可能。
  JigApp/              @main enum JigApp (Main.swift)。stdin/file 読み、
                       stdout/stderr 書き、exit code。Foundation 可。
Tests/JigCoreTests/    JSON / FilterParser / Evaluator / Args の契約テスト。
```

- **JigCore に Foundation を足さない**（Log.swift の既存例外を除く）。
  Swift Static Linux SDK での将来の Linux 配布の道を残すため
  （[docs/jq-compat.md](docs/jq-compat.md) ⑦）。`String(format:)` の代わりに
  `hexString` (JSON.swift) がある。
- **@main は Main.swift の named enum** — top-level の main.swift にすると
  XCTest の `@testable import JigApp` が壊れる（家系共通の罠）。

## Build / Run

| script | 用途 |
|---|---|
| `./build.sh` | swift build -c release → `bin/jig` 配置 + codesign (持続 / ad-hoc) |
| `./run.sh` (無印) / `--demo` | build + デモ filter 実行 (`JIG_DEBUG=1` で trace 付き) |
| `./run.sh --install` / `-i` | `install.sh` 委譲 (`~/.local/bin/jig` 配置・静音) |
| `./install.sh` | build → `~/.local/bin/jig` 配置 |
| `./stop.sh` | 残骸 jig プロセスの pkill。one-shot CLI なので通常 no-op |
| `./setup-signing-cert.sh` | 持続自己署名 identity (`jig-dev`) 作成 |

**ローカルの bar は `swift build`** — この開発機は CommandLineTools のみで
XCTest が無く `swift test` は通らない（`no such module 'XCTest'`）。テストは
CI（build.yml, macos-15 + full Xcode）が回す。turn を終える前に
`swift build` が通っていること。手元の動作確認は
`printf '<json>' | ./bin/jig '<filter>'` のスモークで。

## Non-obvious constraints — read before editing

- **jq 互換契約 (dual-mode)**: **jq モード（既定）** は jq 1.7 と観測可能な
  動作が一致 — 既存 jq プログラムは無変更で動き、`alias jq=jig` が成立する。
  **humane モード（`--humane` / `# jig:humane` pragma / `JIG_MODE=humane`）**
  だけが意味論を意図的に直す。jq モードは決して乖離しない。許す変更は
  (a) 診断改善（両モード）、(b) additive 拡張（両モード）、(c) humane モードで
  **列挙された** 破壊的変更のみ。判断基準・モード差分表・ロードマップは
  [docs/jq-compat.md](docs/jq-compat.md)。互換に触れる変更はそこを
  **同一 PR で** 更新する。
- **generator semantics**: filter は「1 入力値 → 出力値ストリーム」。
  `|` は flatMap、`,` は連結。evaluator は今は eager（`[JigValue]`）—
  lazy 化（`limit`/`first`/無限 generator 対応）は Evaluator.swift の中に
  閉じる設計になっている。
- **JigValue は手書き JSON model** — JSONSerialization は使用禁止。理由は
  jq semantics そのもの: (1) object key の挿入順保存、(2) number literal
  保存、(3) 参照共有のない value 型。
- **number literal 保存** (jq 1.7 準拠): 入力リテラルは演算が触るまで原文
  維持（`JigNumber.literal`）。`12345678901234567890` が `.id` を通っても
  壊れないことがテストで保証される（jq ≤1.6 の最悪バグの再発防止）。
- **エラーは必ず span + hint**: `EvalError` / `FilterParseError` /
  `JSONParseError` 以外の bare throw を増やさない。型名は jq の語彙
  （"cannot index number with …"）を踏襲し、caret 表示は
  Diagnostics.render が一元化。
- **exit codes は jq mirror**: 0 ok / 2 usage・入力エラー / 3 compile
  error / 5 runtime error。runtime error は当該 input の出力を殺すが処理は
  次の input へ続行し、最後に 5 で exit（jq と同じ）。
- **quiet path はゼロ余分 I/O**: glance と違い `/tmp/jig.log` への
  always-on mirror は**無い**（意図的逸脱 — jig は hot loop で呼ばれる
  filter で、jq 1.6 の startup 退行が業界の教訓）。verbose は
  `JIG_DEBUG=1` のみ。`--debug` flag は作らない（家風）。
- **入力はストリーム**: 1 つの stdin/file に whitespace 区切りの複数 JSON
  ドキュメント可（NDJSON 含む）。`JSONStreamParser.next()` ループが正。
- **パーサは落ちない**: 任意バイト列に対し値かエラーのみ（深さ上限 512、
  assert/trap 禁止）。fuzzing 導入は roadmap。

### スコープ確定（再提案しないこと）

- **GUI / panel 表示**: しない。表示端は glance の仕事（`jig … | glance`）。
- **ネットワークアクセス**: しない。fetch は上流（curl 等）の責務。
- **YAML / TOML 入力**: 当面しない（yq の領分）。やるなら別 frontend として
  起票してから。
- **jq と非互換な挙動をデフォルトに入れない**: 破壊的な意味論変更は
  humane モードの中だけ（docs/jq-compat.md のモード差分表に列挙）。jq モードの
  additive 拡張は jq が syntax error にする構文のみ（契約 ④）。

## CLI surface

```
some-cmd | jig [flags] <filter> [files...]
jig explain [flags] <filter>   # filter を平易な説明 + JS 等価で解説
jig check   [flags] <filter>   # compile のみ (CI gate, exit 0/3)

filter (v0 subset — 全 jq 言語へのロードマップは docs/jq-compat.md):
  .          identity            .foo .foo?   field access
  .[0] .[-1] index               .[] .[]?     iterate
  f | g      pipe                f , g        both
  ( ... )    grouping            # ...        comment
  {a: .b}    object construct    [.x] [.[]|f] array construct
  {user}     shorthand (=.user)  {(.k): .v}   computed key
  "a\(f)b"   interpolation       "a${f}b"     ECMAScript alias (=\(f))

flags: -c/--compact-output  -r/--raw-output  -n/--null-input
       --humane  -h/--help  -V/--version  --
input: stdin / file 引数 / `-`(=stdin)。whitespace 区切り複数 doc 可。
       入力無し(対話端末)はハングせず案内 (clig.dev)。
exit:  0 ok / 2 usage・input / 3 compile / 5 runtime
```

試用は同梱の [`sample/foo.json`](sample/foo.json) / [`sample/bar.json`](sample/bar.json)。
I/O 仕様は README の "Input / Output" に集約（clig.dev 準拠）。

flag 名は jq と完全一致させる（筋肉記憶の互換も互換のうち）。短 flag の
結合（`-rc`）は未対応 — jq 側の挙動が不安定なため保留（jq-compat.md）。
`explain` / `check` は jig 固有の subcommand（jq に subcommand は無い）で、
先頭 token のときだけ認識（`.` 始まりの filter や `-flag` とは衝突しない）。
**mode は `--humane` > `# jig:humane` pragma > `JIG_MODE=humane` > 既定 jq**
の優先度で解決（resolveMode in Mode.swift）。`jig explain` は filter の
おおよその JavaScript 等価を出す（JS/TS native 向けの学習ブリッジ）。

## Debugging

| ログ先 | 条件 |
|---|---|
| stderr | diagnostic（常時）、または `JIG_DEBUG=1` の verbose trace |
| `/tmp/jig.log` | `JIG_DEBUG=1` 時のみ trace の写し |
| (なし) | 通常運転は完全に黙る（余分 I/O ゼロ） |

調査の早道:

- 再現を `printf '<json>' | jig '<filter>'` の最小形へ縮める
- `JIG_DEBUG=1` を前置すると filter parse / input サイズの trace が出る
- `./run.sh`（無印）は `JIG_DEBUG=1` 付きでデモを回す

**verbose の唯一のトリガは `JIG_DEBUG` 環境変数**（facet/chord/glance/wand/
perch 家系と統一）。

## Conventions

- **コミット**: gitmoji + Conventional Commits。`scripts/hooks/commit-msg`
  がチェック。有効化: `git config core.hooksPath scripts/hooks`。
  PR タイトルも同じ形式（`commit-lint.yml` がチェック）。
- **バージョン**: `JigVersion.current`（Sources/JigCore/Version.swift）を
  release publish 前に draft の version と同期させる（glance と同じ手動
  運用）。
- **依存**: 原則ゼロを維持。足すなら MIT / Apache-2 互換限定 +
  Package.swift に WHY コメント + PR description に根拠（build time /
  binary size への影響込み）。
- **コメント**: WHY を書く。WHAT は識別子で語る。
- **README**: README.md と README.ja.md はユーザ可視の変更と同一 PR で同期。

## CI (.github/workflows)

| ファイル | 役割 |
|---|---|
| `build.yml` | PR/push で macos-15 上 `./build.sh` + `swift test` + バイナリ sanity |
| `shellcheck.yml` | shell スクリプトの lint |
| `commit-lint.yml` | commit / PR title の convention チェック（akira-toriyama/.github へ委譲） |
| `taplo.yml` | TOML lint（akira-toriyama/.github へ委譲） |
| `glossary.yml` | docs/glossary.md → glossary site deploy（akira-toriyama/glossary-site へ委譲） |
| `release.yml` | git-cliff (`cliff.toml`) rolling-draft リリース + bin/jig 添付 |
| `update-tap.yml` | release publish 後に `akira-toriyama/homebrew-tap` の Formula/jig.rb を bump |

`update-tap.yml` は `HOMEBREW_TAP_TOKEN`（homebrew-tap だけに scope した
fine-grained PAT, Contents: RW）が必要。未設定なら安全に skip。**初回の
formula は手動で tap に置く**（workflow は bump 専用）—
canonical copy は `packaging/homebrew/jig.rb`。

## References (家風 + 実装資料)

家風（流儀を意図的に揃えている）:

- [glance](https://github.com/akira-toriyama/glance) — 最も近い兄弟 (one-shot CLI)。`jig … | glance` が想定連携
- [chord](https://github.com/akira-toriyama/chord) / [facet](https://github.com/akira-toriyama/facet) — 依存ゼロ Core / CI / release の先行例
- [atelier](https://github.com/akira-toriyama/atelier) — family roster。GitHub に repo を作ったら apps.txt に `jig` を追加

実装資料（jq 互換の一次情報）:

- [jq manual](https://jqlang.org/manual/) — 言語仕様の正
- [jqlang/jq `tests/jq.test`](https://github.com/jqlang/jq/blob/master/tests/jq.test) — conformance suite の種（roadmap: golden test 化）
- [jqlang/jq `src/builtin.jq`](https://github.com/jqlang/jq/blob/master/src/builtin.jq) — jq 自身が jq で定義する builtin 群
- [gojq README](https://github.com/itchyny/gojq#difference-to-jq) — 意図的な jq との差分カタログ（乖離判断の先行事例として最重要）
- [jaq](https://github.com/01mf02/jaq) — Rust 実装の設計・性能の参照点
- [docs/jq-compat.md](docs/jq-compat.md) — このリポジトリの互換規範（jq の不評点 → jig の方針の対応表）
