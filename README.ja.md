# jig

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-early%20WIP-red)

[English](README.md) · **日本語**

**人に優しい診断を備えた JSON プロセッサ**。jig は小さな jq 由来の
filter 言語を話す — ただし失敗した時は、filter の **どこ** で、
**何** に出会い、**次に何を試すべきか** を伝える:

```console
$ echo '5' | jig '.name'
jig: error: cannot index number with "name" (input #1)
  .name
  ^^^^^
  hint: use .name? to skip inputs where this isn't an object
```

（jq も `Cannot index number with "name"` を出す — が、filter の **どこ** で
間違ったかを示す caret は付かない。）

*jig*（治具）は工房で素材を固定し刃の通り道を導く道具 — query program が
JSON に対してやることそのもの。Swift ツール家系
[atelier](https://github.com/akira-toriyama/atelier) の一員。

> ⚠️ **開発初期 (WIP) — 方針転換 (2026-06-13)。** jig は **人に優しい JSON
> 操作 CLI** へ向かう: jq 由来の文法（Unix 純な `|` パイプ）+ lodash/es-toolkit
> 風の builtin 語彙 + 人に優しい診断。jq の**完全バイト互換はもう追わない**
> （それは jq/gojq/jaq の仕事）。現状は小さな jq ライクのコアのみ実装
> （下の *現在対応*）。向かう先と理由は **[ロードマップ](docs/roadmap.md)**。

## なぜもう一つの jq?

jq は素晴らしいツールで、jig はその最良のアイデア — *JSON + Unix パイプ* —
だけを継承する。**jq 互換は追わない**（必要なら jq/gojq/jaq を使う）。その上で、
長年の不満点を実装レベルで直す:

- **診断。** すべてのエラーが source span（filter の下に caret）、jq 語彙の
  型名、hint を持つ。bison 語のエラーも、位置情報なしの実行時エラーも
  出さない。チャットからコピペした smart quote や、shell に食われた quote
  も検出して説明する。
- **数値が壊れない。** `12345678901234567890` がそのまま round-trip する
  （jq 1.7 の literal 保存。jq ≤1.6 の silent corruption は regression
  test 化済み）。
- **クラッシュしない。** 手書きパーサは任意のバイト列に対して「値」か
  「親切なエラー」のどちらかを返す。assert 落ちは出さない。
- **デフォルトで静かで速い。** 正常系の余分 I/O はゼロ。起動時間は管理
  対象の予算（jq 1.6 の起動 10 倍退行が反面教師）。

jig は **意味論ひとつ** — モード切り替えは無い。より良い書き方が無い jq の
綴りは残し（`//` は `false`/`null` をフォールバック対象にする、`?` で省略可能な
アクセス）、明確により良いデフォルトがある所では理に適った方を採る: `null` の
イテレートはエラーではなく空を返す（`null` が `.foo` / `.[N]` を素通りするのと
一貫）、ECMAScript の `??` は nullish のみのフォールバック（`null` を落とし、
`false` は残す）。言語が次に向かう先は **[ロードマップ](docs/roadmap.md)**。

## Usage

```sh
curl -s https://api.example.com/users | jig '.[] | .name'   # パイプから
jig -r '.maintainers[].name' sample/project.json                # ファイルから
cat sample/project.json | jig -c '.tags' -                      # `-` = stdin
```

### Try it

リポジトリに 2 つのサンプル ([`sample/`](sample/)) を同梱:

```console
$ jig -r '.maintainers[] | .name' sample/project.json
ann
bob
cy

$ jig -c '.maintainers | map(select(.active))' sample/project.json
[{"name":"ann","active":true,"commits":128},{"name":"cy","active":true,"commits":7}]

$ jig '.maintainers | map(.commits) | add' sample/project.json
177

$ jig '.repo.big_id' sample/project.json          # 64bit id をそのまま保存
12345678901234567890

# // は false+null を落とす / ?? (nullish) は false を残す — orders.json で比較
$ jig -c 'map(.shipped // "pending")' sample/orders.json
["pending",true,"pending"]
$ jig -c 'map(.shipped ?? "pending")' sample/orders.json
["pending",true,false]

$ jig -r '.maintainers[] | "\(.name) → \(.commits) commits"' sample/project.json
ann → 128 commits
bob → 42 commits
cy → 7 commits

$ jig explain '.maintainers[] | .name'        # 平易な解説 + JS 等価
  …
  ≈ JS: input.maintainers.map(x => x.name)
```

### 現在対応 (v0)

`.` `.foo` `.foo?` `.[0]` `.[-1]` `.[]` `.[]?` `|` `,` `( … )` `# コメント`、
scalar リテラル (`42` `"s"` `true` `false` `null`)、オブジェクト / 配列構築
(`{a: .b}`、短縮形 `{user}`、計算キー `{(.k): .v}`、`[.x, .y]`)、
文字列補間 `"a\(.x)b"`（additive な ECMAScript 表記 `"a${.x}b"` も可）、
`a // b`、`a ?? b`、算術 `+ - * / %`（`"s"*n`・`arr-arr`・`obj+obj` マージ /
`obj*obj` ディープマージ・`str/str` split を含む）、比較 `== != < <= > >=`
（jq のクロス型全順序）、論理 `and` / `or`、単項マイナス `-x`、
builtin `length keys keys_unsorted typeof not reverse sum empty map(f)
filter(f) has(k)`（jq alias `type` / `add` / `select` も受理）。subcommand
`jig explain` / `jig check`。全体像とロードマップ:
[docs/roadmap.md](docs/roadmap.md)。

## Input / Output

jig は Unix filter で、[clig.dev](https://clig.dev) に沿う:

- **入力** — JSON を **stdin** / **ファイル引数** / `-`(stdin) から読む。
  1 つの入力に whitespace 区切りの複数ドキュメント(NDJSON 含む)を置け、
  順に処理する。
- **stdout** — JSON 結果を 1 値 1 行で出力。既定は 2-space pretty、`-c` で
  compact、`-r` で top-level 文字列を raw(引用符なし)。
- **stderr** — diagnostic 専用(エラー・hint・`JIG_DEBUG` trace)。stdout の
  データを汚さない。
- **exit code**(jq 互換): `0` ok ・ `2` usage / 読めない・壊れた入力 ・
  `3` filter compile error ・ `5` 実行時エラー発生。
- **入力が無い**(対話端末)ときはハングせず案内を表示 — パイプ・ファイル・
  `-n` のいずれかを使う。

## Install

ソースから（macOS 13+, Swift 6 toolchain）:

```sh
git clone https://github.com/akira-toriyama/jig.git
cd jig
./install.sh          # build して ~/.local/bin/jig に配置
```

Homebrew（`brew install akira-toriyama/tap/jig`）は最初のリリース公開後に
利用可能になる予定。

## Development

```sh
./build.sh            # swift build -c release → bin/jig (codesign 付き)
./run.sh              # build + JIG_DEBUG=1 でデモ filter 実行
swift test            # full Xcode (XCTest) が必要。CI が全 PR で実行
```

verbose trace は環境変数のみ（家風）: `JIG_DEBUG=1 jig …` で stderr と
`/tmp/jig.log` に trace が出る。`--debug` flag は無い。

アーキテクチャと制約は [CLAUDE.md](CLAUDE.md)、方針と builtin 語彙は
[docs/roadmap.md](docs/roadmap.md)、正規用語は
[docs/glossary.md](docs/glossary.md)、コミット/リリースの流れは
[docs/commit-convention.md](docs/commit-convention.md)、そして
**廃止済み (SUPERSEDED / 歴史的参考)** の jq 互換メモは
[docs/jq-compat.md](docs/jq-compat.md)。

## Family

jig は [atelier](https://github.com/akira-toriyama/atelier) の家風
— SwiftPM ヘキサゴナル層、gitmoji + Conventional Commits、git-cliff
rolling-draft リリース、Homebrew tap 配布 — に従う。兄弟:
[chord](https://github.com/akira-toriyama/chord) /
[facet](https://github.com/akira-toriyama/facet) /
[glance](https://github.com/akira-toriyama/glance)
（`… | jig -r '.text' | glance --markdown` の連携が想定形）/
[perch](https://github.com/akira-toriyama/perch) /
[sill](https://github.com/akira-toriyama/sill) /
[wand](https://github.com/akira-toriyama/wand)。

## License

[MIT](LICENSE)
