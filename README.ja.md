# jig

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-early%20WIP-red)

[English](README.md) · **日本語**

**人に優しいエラーを持つ jq 互換 JSON プロセッサ**。jig は jq の filter を
jq の意味論のまま実行する — ただし失敗した時は、filter の **どこ** で、
**何** に出会い、**次に何を試すべきか** を伝える:

```console
$ echo '{}' | jig '.items[]'
jig: error: cannot iterate over null (null) (input #1)
  .items[]
        ^^
  hint: use .[]? to skip non-iterable inputs, or // [] to default missing data
```

（jq だと: `jq: error (at <stdin>:0): Cannot iterate over null (null)`）

*jig*（治具）は工房で素材を固定し刃の通り道を導く道具 — query program が
JSON に対してやることそのもの。Swift ツール家系
[atelier](https://github.com/akira-toriyama/atelier) の一員。

> ⚠️ **開発初期 (WIP)。** 現在は jq 言語の小さなコア部分のみ実装
> （下の *Usage* 参照）。基盤 — stream 処理、診断、number literal 保存、
> jq 互換 exit code — は完成済みで、言語表面を完全互換へ向けて拡張中
> （[ロードマップ](docs/jq-compat.md)）。

## なぜもう一つの jq?

jq は素晴らしいツールで、jig は jq との互換を守る
（[互換性契約](docs/jq-compat.md)）。その上で、長年の不満点を実装レベルで
直す:

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

jig が **やらない** こと: jq プログラムを壊すこと。言語拡張は additive
のみ（例: `//` と違い `false` を欠損扱いしない `??` を計画中）。

## Usage

```sh
curl -s https://api.example.com/users | jig '.[] | .name'
jig -r '.items[0].id' data.json
echo '{"a":{"b":[1,2,3]}}' | jig -c '.a.b[]'
```

現在対応の filter 構文 (v0): `.` `.foo` `.foo?` `.[0]` `.[-1]` `.[]`
`.[]?` `|` `,` `( … )` — 加えて `-c` / `-r` / `-n`、複数ドキュメント入力
stream（NDJSON）、jq 互換 exit code（0 / 2 usage / 3 compile /
5 runtime）。全体像とロードマップ: [docs/jq-compat.md](docs/jq-compat.md)。

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

アーキテクチャと制約は [CLAUDE.md](CLAUDE.md)、正規用語は
[docs/glossary.md](docs/glossary.md)、コミット/リリースの流れは
[docs/commit-convention.md](docs/commit-convention.md)、互換ポリシーは
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
