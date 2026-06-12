# jq compatibility policy — jig の互換規範

jig が「jq とどこまで同じで、どこを変えてよいか」の **規範ドキュメント**。
互換性に触れる変更は、この文書の更新と **同一 PR** で行う。

基準にする jq: **jq 1.7.x**（jqlang/jq）。

## 互換性契約 (the contract)

1. **既存の jq プログラムの観測可能な動作を変えない。** stdout に出る
   バイト列と exit code が契約。jq 1.7 で動くプログラムは jig でも同じ
   出力を生む（未実装ならエラーになるのは可、**違う結果を黙って返すのは
   不可**）。
2. **診断（stderr）は契約に含めない。** エラーメッセージ・位置情報・hint は
   jq より良くしてよい。ここが jig の存在理由。
3. **flag 名は jq と完全一致。** `-r` `-c` `-n` `--arg` … 筋肉記憶の互換も
   互換のうち。jig 独自 flag は long form のみで追加し、jq の将来の短
   flag と衝突させない。
4. **exit code は jq mirror**: 0 ok / 2 usage・入力エラー / 3 compile
   error / 5 runtime error（将来 `-e` 導入時は 1 / 4 も jq 準拠）。
5. **言語拡張は additive のみ。** 新しい演算子・builtin は「jq 1.7 で
   syntax error になる構文」だけに割り当てる（例: `??`）。既存構文の意味は
   絶対に変えない。

## jq の不評点 → jig の方針

調査（HN / GitHub issues / 代替実装の差分）で挙がった主要な不満と、jig の
対応方針。**[診断]** = 契約2の範囲（semantics 不変）、**[追加]** = 契約5の
additive 拡張、**[修正]** = jq 自身がバグ/未定義として扱う領域の改善。

| # | jq の不評点 | jig の方針 |
|---|---|---|
| 1 | 実行時エラーに位置情報が無い（`Cannot iterate over null (null)` だけ） | **[診断]** 全 AST node が SourceSpan を保持。エラーは program 内位置 + caret + 型名 + `?` の hint。**実装済み (v0)** |
| 2 | パーサエラーが bison 語（`unexpected INVALID_CHARACTER, expecting $end`）、一部入力で assert 落ち | **[診断]** 手書き recursive-descent。smart quote / shell quoting / `$` 展開ミスを検出して具体的 hint。任意入力で crash しない（深さ上限 + 将来 fuzzing）。**実装済み (v0)** |
| 3 | `//` が `false` を「欠損」扱いする | **[追加]** `//` は互換のまま維持。null/欠損のみ落ちる `??`（nullish coalescing）を additive に追加（jq 1.7 では syntax error の構文なので安全）。roadmap |
| 4 | null 伝播の非一貫性（`.foo` は ok、`.foo[]` はエラー）で `?` だらけになる | **[診断]** default semantics は互換維持。エラーメッセージが常に `?` 形を提案 + null 挙動の一覧表を docs に。**実装済み (v0)**（一覧表は本表の下） |
| 5 | 巨大入力で全量メモリ展開、`--stream` は別言語級に難解 | **[追加]** incremental parse + top-level array の要素を stream として流す opt-in モード（多くの「巨大 JSON」はこの形）。`--stream` 自体は互換維持。roadmap（JSONStreamParser は既に streaming 前提の API） |
| 6 | jq 1.6 の startup 10x 退行（builtin link が quadratic） | **[修正]** builtin prelude はビルド時に固める。CI に startup benchmark gate（目標 cold start < 5ms）。roadmap |
| 7 | regex が「PCRE と書いて Oniguruma」、ビルドにより regex 無し、gsub が指数的に遅い | **[修正]** エンジンを内蔵（optional dependency にしない）。対応構文の conformance 表を docs 化。literal-string fast path。roadmap |
| 8 | 大整数が silently 壊れる（≤1.6）、1.7 でも演算で壊れる | **[修正]** literal 保存は **実装済み (v0)**（`JigNumber.literal`）。演算導入時は gojq 方式（整数は任意精度、分数/オーバーフローで double 化）を採る。roadmap |
| 9 | date/time builtin が libc 任せで OS により結果が違う（%z 無視など） | **[修正]** プラットフォーム非依存の strptime/strftime を内蔵（gojq の先例）。roadmap |
| 10 | `@base64d` が unpadded / URL-safe を拒否（JWT が読めない） | **[修正]** 両 alphabet + padding 省略を受理（strict は opt-in）。`@base64url` / `@base64urld` を追加。roadmap |
| 11 | `\(…)` 補間が shell escape と衝突 | **[診断]** backslash が shell に食われた形跡を検出して hint。roadmap（string literal 実装と同時） |
| 12 | reduce/foreach が難解 | **[追加]** semantics は互換。`sum_by` 等の高位 builtin を additive に検討。roadmap 後期 |
| 13 | `--arg` が全部 string | **[診断]** string $var と number の `==` 比較に stderr warning（抑制可）。roadmap |
| 14 | メモリ安全バグが長年放置された | **[修正]** Swift (memory-safe) + パーサ fuzzing を CI に。fuzzing は roadmap |
| 15 | ドキュメントが「ストリームの言語」だと教えてくれない | docs: generator semantics を最初に教えるチュートリアル + 本表のような規範 spec を維持 |

### null 挙動の一覧（契約1の確認表）

| 式 | 入力 null | 入力 scalar | 入力 {} / [] |
|---|---|---|---|
| `.foo` | `null` | **error** (`?` で空) | `null` / error |
| `.[0]` | `null` | **error** (`?` で空) | error / `null`（範囲外も `null`） |
| `.[]` | **error** (`?` で空) | **error** (`?` で空) | 空ストリーム |

## 実装ロードマップ（互換 surface の拡張順）

v0 = 現在。各段で jq.test の該当セクションを golden test として取り込む。

1. **v0（実装済み）** — `.` `.foo` `.foo?` `.[N]` `.[]` `|` `,` `(…)`、
   `-c` `-r` `-n`、stream 入力、literal 保存、診断基盤
2. リテラル（number/string/bool/null）、object/array construction
   (`{a: .b}` `[.x]`)、文字列補間 `\(…)`
3. 算術・比較・論理（`+ - * / %`, `== != < >`, `and or not`）、
   `//`、**`??` [追加]**
4. builtin 第1波: `length` `keys` `map` `select` `has` `type` `empty`
   `range` `add` `to_entries` 系
5. 変数 `as`、`def`、`reduce` / `foreach`、`if/then/elif/else/end`、
   `try/catch`、path 式と代入 (`=` `|=` `+=`)
6. `@text` 等 format 群、regex（`test` `match` `capture` `gsub`）、
   date/time、`--arg` `--argjson` `--slurp` 他 flag 完全化
7. lazy evaluator 化（`limit` `first` `repeat` `until`）、`$ENV` /
   `env`、module system（`import`）、`--stream`
8. conformance: jqlang/jq `tests/jq.test` の通過率を CI で計測・公開、
   gojq の差分カタログと突き合わせて乖離を文書化

### 静的 Linux 配布（nice-to-have）

JigCore は Foundation 非依存を維持（Log.swift のみ例外、JigApp は
Foundation 可）。Swift Static Linux SDK (musl) で macOS から静的 ELF を
cross-compile できる状態を保つ。Linux は best-effort artifact であって
support promise ではない。

## 参照

- jq manual: https://jqlang.org/manual/
- jq test suite: https://github.com/jqlang/jq/blob/master/tests/jq.test
- jq builtins (jq 定義): https://github.com/jqlang/jq/blob/master/src/builtin.jq
- gojq の意図的差分（先行事例）: https://github.com/itchyny/gojq#difference-to-jq
- jaq の意図的差分: https://github.com/01mf02/jaq#differences-between-jq-and-jaq
