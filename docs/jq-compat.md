# jq compatibility policy — jig の互換規範

> ⚠️ **2026-06-13 以降 SUPERSEDED — このドキュメントは歴史的参考資料です。**
> 方向性の正本は **[docs/roadmap.md](roadmap.md)**（jig = 人に優しい JSON 操作
> CLI、Unix 純パイプ + lodash 語彙 + humane 診断）。
>
> - jig は **jq 互換をもはや追求しない**。
> - **dual-mode 契約（jq モード / humane モード）と、その H1/H2 モード差分表は
>   実装をもう記述していない。** `--humane` フラグ・`JIG_MODE`・`# jig:humane`
>   pragma・`Mode.swift` はコードから**撤去済み**。
> - jig は今や **単一の意味論**を持つ: `.[]` を null に適用 → **空ストリーム**、
>   `//` は **false + null を落とす**、`??` は **nullish**。
> - 本ファイルの「jq モードは決して乖離しない」契約は**無効**。
> - ただし **差分カタログ・診断哲学・null 挙動表・ECMAScript エルゴノミクス表は
>   参考資料として有効** なので、**歴史的参考**として残す。

jig が「jq とどこまで同じで、どこを変えてよいか」の（旧）規範ドキュメント。
※以下は転換前の文面（歴史的参考資料）。

基準にする jq: **jq 1.7.x**（jqlang/jq）。

## 互換性契約 (the contract) — dual-mode

> ⚠️ 歴史的記述（dual-mode は撤去済み・docs/roadmap.md 参照）

jig は **2 つのモード**を持つ。**jq モード（デフォルト）** は jq 1.7 と
観測可能な動作が一致する。**humane モード（opt-in）** は jq の意味論の
ワルを意図的に直す（互換を壊す）モード。drop-in 置き換えと「サニティな
言語」を両取りするための設計。

1. **デフォルトは jq モード。** stdout のバイト列と exit code が契約で、
   jq 1.7 で動くプログラムは jq モードの jig でも同じ出力を生む。
   `alias jq=jig` が成立し、jq の conformance suite はこのモードを検証する。
2. **破壊的な意味論変更は humane モードの中だけで許す。** jq モードは決して
   乖離しない。humane で変わる挙動は下の「モード差分表」に **全て列挙** し、
   そこに無い破壊的変更はしない。
3. **診断（stderr）は両モードとも契約外。** エラーメッセージ・位置情報・
   hint は常に改善してよい。ここが jig の存在理由。
4. **additive 拡張は両モードで使える。** jq 1.7 で syntax error になる構文
   （例: `??`）に割り当てた新演算子・builtin は、jq モードでも humane でも
   同じく使える（既存プログラムを壊さないため）。
5. **flag 名は jq と一致。** `-r` `-c` `-n` `--arg` … jig 独自 flag は
   long form のみで追加し、jq の将来の短 flag と衝突させない。
6. **exit code は jq mirror**: 0 ok / 2 usage・入力エラー / 3 compile
   error / 5 runtime error（将来 `-e` 導入時は 1 / 4 も jq 準拠）。

### モードの選び方（優先度 高→低）

> ⚠️ 歴史的記述（dual-mode は撤去済み・docs/roadmap.md 参照）

1. CLI flag `--humane`（long-form のみ）
2. プログラム先頭の pragma 行 `# jig:humane`（jq は `#` をコメント扱い
   するので、pragma 付きプログラムも jq でそのまま parse できる — 挙動が
   付かないだけ）
3. 環境変数 `JIG_MODE=humane`
4. 既定 = jq モード

> モード機構の実装は最初の humane 挙動（H1/H2, roadmap 段階 3）と同時に
> 入る。それまで `--humane` は未知 flag。

### モード差分表（humane で変わる挙動の全リスト）

> ⚠️ 歴史的記述（dual-mode は撤去済み・docs/roadmap.md 参照）

humane モードで jq と意図的に異なる挙動になるのは **以下だけ**。各項目は
jq モードでは jq 1.7 と一致する。新しい humane 挙動を足すときは、この表に
1 行追加するのと同一 PR で行う。

| ID | 挙動 | jq モード (既定) | humane モード |
|---|---|---|---|
| H1 | `a // b`（alternative operator） | jq 互換: `a` が `false`/`null` でも `b` に落ちる | nullish: `a` が `null`/空のときだけ `b`。`false`/`0`/`""` は保持 |
| H2 | `null \| .[]`（null のイテレート） | **error**（`?` で空） | 空ストリーム（null が静かに素通り — `?` 不要） |

> `??`（nullish coalescing）は **両モードで使える** additive 演算子。jq
> モードで「false を保持したい」なら `//` ではなく `??` を使う。humane
> モードは `//` 自体を `??` 相当にする。
>
> 破壊リスクが高い次の項目は humane でも **変えず**、linter（`jig lint`,
> roadmap）の警告に留める: `=` の RHS がルート評価される件 / `$x as` の
> 束縛順が直感と逆な件。`limit`/`first` の端や NaN のソート順は jq 1.7 の
> 修正済み挙動を **両モードの** baseline にする（バグ領域なので破壊では
> ない）。

## jq の不評点 → jig の方針

調査（HN / GitHub issues / 代替実装の差分）で挙がった主要な不満と、jig の
対応方針。**[診断]** = 契約3（両モード共通、semantics 不変）、**[追加]** =
契約4 の両モード additive 拡張、**[humane]** = humane モードの opt-in 挙動
変更（モード差分表 参照）、**[修正]** = jq 自身がバグ/未定義として扱う領域の
改善（両モード）。

| # | jq の不評点 | jig の方針 |
|---|---|---|
| 1 | 実行時エラーに位置情報が無い（`Cannot iterate over null (null)` だけ） | **[診断]** 全 AST node が SourceSpan を保持。エラーは program 内位置 + caret + 型名 + `?` の hint。**実装済み (v0)** |
| 2 | パーサエラーが bison 語（`unexpected INVALID_CHARACTER, expecting $end`）、一部入力で assert 落ち | **[診断]** 手書き recursive-descent。smart quote / shell quoting / `$` 展開ミスを検出して具体的 hint。任意入力で crash しない（深さ上限 + 将来 fuzzing）。**実装済み (v0)** |
| 3 | `//` が `false` を「欠損」扱いする | **[追加 + humane]** null/欠損のみ落ちる `??`（nullish coalescing）を additive に追加し **両モードで** 提供。さらに humane モードでは `//` 自体を nullish 化（H1）。jq モードの `//` は互換維持。roadmap |
| 4 | null 伝播の非一貫性（`.foo` は ok、`.foo[]` はエラー）で `?` だらけになる | **[診断 + humane]** jq モードは互換維持 + エラーが常に `?` 形を提案。humane モードでは null のイテレートが空ストリーム（H2）。一覧表は本表の下。**診断は実装済み (v0)** |
| 5 | 巨大入力で全量メモリ展開、`--stream` は別言語級に難解 | **[追加]** incremental parse + top-level array の要素を stream として流す opt-in モード（多くの「巨大 JSON」はこの形）。`--stream` 自体は互換維持。roadmap（JSONStreamParser は既に streaming 前提の API） |
| 6 | jq 1.6 の startup 10x 退行（builtin link が quadratic） | **[修正]** builtin prelude はビルド時に固める。CI に startup benchmark gate（目標 cold start < 5ms）。roadmap |
| 7 | regex が「PCRE と書いて Oniguruma」、ビルドにより regex 無し、gsub が指数的に遅い | **[修正]** エンジンを内蔵（optional dependency にしない）。対応構文の conformance 表を docs 化。literal-string fast path。roadmap |
| 8 | 大整数が silently 壊れる（≤1.6）、1.7 でも演算で壊れる | **[修正]** literal 保存は **実装済み (v0)**（`JigNumber.literal`）。算術 (`+ - * / %`) は **実装済み (v0)**: jq 1.7 と同じく未演算リテラルのみ保存し、演算は double 化。gojq 方式の任意精度整数は jq と乖離するので **humane 拡張**として roadmap（採用時はモード差分表に 1 行追加）。**既知の未修正ギャップ（数値シリアライズ正規化）**: jig は literal の原文を **そのまま** 出すが、jq は精度に関わらない数値を dtoa で **正規化** する（`1e10`→`1E+10`、`1e-5`→`0.00001`、`1e0`→`1`、`-0`→`0`、`0.5e1`→`5`）。そのため指数表記・冗長表記・負ゼロの数値**出力**が jq モードでも現状 jig と乖離する（bare 出力・construction・算術・文字列補間すべて同じ。`12345678901234567890` のような精度保持対象は一致）。これは **formatter の問題（`JSONWriter.formatNumber` / `JigNumber`）で補間機能とは独立** — jq の dtoa 出力にバイト一致させる **専用 PR**（数値オラクルスイート付き）で対応する。同様に **文字列の制御文字エスケープ**も gap: jq は `0x7F`(DEL) 等を `\u007f` でエスケープするが jig の `writeString` は `<0x20` のみエスケープする（同 PR 圏内）。 |
| 9 | date/time builtin が libc 任せで OS により結果が違う（%z 無視など） | **[修正]** プラットフォーム非依存の strptime/strftime を内蔵（gojq の先例）。roadmap |
| 10 | `@base64d` が unpadded / URL-safe を拒否（JWT が読めない） | **[修正]** 両 alphabet + padding 省略を受理（strict は opt-in）。`@base64url` / `@base64urld` を追加。roadmap |
| 11 | `\(…)` 補間が shell escape と衝突 | **[診断]** `\(…)` / `${…}` 補間は **実装済み (v0)**（step 2）。未終端補間（`"\(.x"`）は「inside `\( … )` string interpolation — expected `)`」と span 付きで案内。backslash を shell に食われた形（`"(.x)"` がただのリテラルに化ける）の自動検出は、有効な文字列を誤検出するリスクが高いため見送り（`(.x)` は正当な文字列）。additive な `${…}` も同じ補間にマップし、shell が `\` を食う問題自体を回避できる |
| 12 | reduce/foreach が難解 | **[追加]** semantics は互換。`sum_by` 等の高位 builtin を additive に検討。roadmap 後期 |
| 13 | `--arg` が全部 string | **[診断]** string $var と number の `==` 比較に stderr warning（抑制可）。roadmap |
| 14 | メモリ安全バグが長年放置された | **[修正]** Swift (memory-safe) + パーサ fuzzing を CI に。fuzzing は roadmap |
| 15 | ドキュメントが「ストリームの言語」だと教えてくれない | docs: generator semantics を最初に教えるチュートリアル + 本表のような規範 spec を維持 |

### null 挙動の一覧（jq モードの確認表）

下表は **jq モード**（既定）の挙動。humane モードでは H2 により
「`.[]` × 入力 null」セルが **空ストリーム** に変わる（他セルは不変）。

| 式 | 入力 null | 入力 scalar | 入力 {} / [] |
|---|---|---|---|
| `.foo` | `null` | **error** (`?` で空) | `null` / error |
| `.[0]` | `null` | **error** (`?` で空) | error / `null`（範囲外も `null`） |
| `.[]` | **error** (`?` で空、humane では空) | **error** (`?` で空) | 空ストリーム |

## 実装ロードマップ（互換 surface の拡張順）

v0 = 現在。各段で jq.test の該当セクションを golden test として取り込む。

1. **v0（実装済み）** — `.` `.foo` `.foo?` `.[N]` `.[]` `|` `,` `(…)`、
   `#` コメント、`-c` `-r` `-n`、stream 入力、literal 保存、診断基盤、
   **mode 機構（`--humane` / `# jig:humane` / `JIG_MODE`）+ H2**、
   **`jig explain`（JS 等価つき）+ `jig check`**
2. **完全に実装済み (v0)**。**scalar リテラル（number/string/bool/null）**、
   **object / array construction**: `{a: .b}`、短縮形 `{user}`
   (≡ `{user: .user}`)、文字列キー `{"a b": .x}`、計算キー `{(.k): .v}`、
   配列 `[.x, .y]` / `[.[] | f]` / `[]`。キー/値の generator は jq と同じ
   **カルテシアン積**（entry は左が外側、1 ペア内は key が value より外側＝
   `k as $k | v as $v` 順）、重複キーは **last-wins・最初の位置を保持**、空
   ストリームは積を空にする — いずれも jq 1.8 と byte 単位で一致を検証。
   **文字列補間 `\(…)`**: literal 断片 + 埋め込み filter（full pipe）の列。
   coercion は jq の `tostring`（string はそのまま、それ以外は compact JSON。
   `\(1)`→"1" / `\("x")`→"x" / `\(null)`→"null" / `\([1,2])`→"[1,2]" /
   `\({"a":1})`→`{"a":1}` の compact 形）、number は literal 保存が乗る
   (`\(1.0)`→"1.0")。複数補間は **最右が最も外側（slowest）** のカルテシアン積
   （`"\(1,2)-\(3,4)"` → 1-3,2-3,1-4,2-4）、空ストリーム（`\(empty)`）は全体を
   空にする — jq 1.8 と byte 単位で一致を検証。文字列キーにも効く
   (`{"\(.n)": 1}`)。
   **`${…}` は `\(…)` の additive な ECMAScript エイリアス**（下表 / 本項の
   既知差分）。
   - 既知の小乖離（常に壊れているプログラムのみ・drop-in 性に影響なし）:
     **非文字列の定数キー**（`{(1): 2}` `{(1+1): 2}`）は jq が compile 時に
     定数畳み込みで弾く（exit 3）が、jig は定数畳み込みを持たないため
     **実行時エラー（exit 5）** になる。両者とも出力は生まない。動的キー
     （`{(.k): …}` で `.k` が非文字列）は両者とも実行時 exit 5 で一致。
   - **`${…}` は additive 拡張**（契約 ④ の精神）: jq は文字列中の `${` を
     **ただのリテラル文字**として扱う（`"a${x}b"`→`"a${x}b"`）。jig は両モードで
     これを `\(…)` 同義の補間として解釈する — additive 構文が「jq では構文
     エラーになる形」ではなく「jq では無害なリテラル文字列」に意味を与える
     **唯一の地点**。実用上 `${…}` をリテラルとして書く jq プログラムは
     ほぼ存在しないため drop-in 性への影響は無視できるが、契約 ④ の文言の
     例外としてここに明記する。素の `$`（`{` を伴わない）はリテラルのまま
     （jq 一致）。`\(…)` 自体は jq と完全一致。
   - **数値の出力正規化ギャップ**（補間 **以外**にも共通・補間機能とは独立）:
     `"\(1e10)"` は jq が `"1E+10"`、jig が `"1e10"`（`1e-5`→jq `0.00001`、
     `-0`→jq `0` 等も）。これは jig の number formatter が literal をそのまま
     出すため bare 出力・construction・算術でも同様に出る既存ギャップで、
     **不評点 #8 の「数値シリアライズ正規化」**に集約。jq の dtoa にバイト
     一致させる **専用 PR** で対応する（補間のテストは jq と一致する数値
     ケースのみを golden にしている）。
3. **`//` + `??`（+ H1 humane）実装済み (v0)**、**mode 機構（`--humane` /
   `# jig:humane` / `JIG_MODE`）+ H1・H2 実装済み**、**算術・比較・論理
   （`+ - * / %`、`== != < <= > >=`、`and` / `or`、単項マイナス `-`）
   実装済み (v0)**。`not` は builtin（段階 4）。比較は jq の全型順序
   （null < false < true < number < string < array < object）。算術は jq 1.7
   同様 double で評価（#8 参照）
4. **builtin 第1波 実装済み (v0)**: `length` `keys` `keys_unsorted` `type`
   (`typeof`) `not` `reverse` `add` `empty` `map(f)` `select(f)` (`filter`)
   `has(k)`。残: `range` `to_entries` `select`系の述語拡張 等
5. 変数 `as`、`def`、`reduce` / `foreach`、`if/then/elif/else/end`、
   `try/catch`、path 式と代入 (`=` `|=` `+=`)
6. `@text` 等 format 群、regex（`test` `match` `capture` `gsub`）、
   date/time、`--arg` `--argjson` `--slurp` 他 flag 完全化
7. lazy evaluator 化（`limit` `first` `repeat` `until`）、`$ENV` /
   `env`、module system（`import`）、`--stream`
8. conformance: jqlang/jq `tests/jq.test` の通過率を CI で計測・公開、
   gojq の差分カタログと突き合わせて乖離を文書化

## ECMAScript 由来のエルゴノミクス

JSON は元々 JavaScript のオブジェクトリテラル。JS/TS に慣れた利用者の
直感をそのまま使えるよう、ECMAScript の構文・命名・null 扱いを **additive**
（両モード）か **humane**（opt-in）で取り込む。各項目は jq 1.7 で
syntax error になる構文か、humane モードに限定するので互換は壊さない。

| 由来 | jig での扱い | 区分 | 状態 |
|---|---|---|---|
| `??` nullish coalescing | `a ?? b`（`null`/空のときだけ `b`）。jq の falsy な `//` の対極 | [追加] | roadmap 3 |
| `?.` optional chaining | `.a?.b` を null-safe field access の sugar に（jig の `.a?` と同義の JS 表記） | [追加] | roadmap 5 |
| `${...}` template literal | 文字列補間 `\(…)` の同義として `"${expr}"` を受理（両モード。jq は `${` をリテラル扱いするので、これは additive が「無害なリテラル」に意味を与える唯一例外 — roadmap 2 項の既知差分に明記） | [追加] | **実装済み (v0)** |
| spread `...` | 構築での展開: `{...$base, id: 1}` / `[...$xs, 4]` | [追加] | roadmap 5 |
| `//` = JS の falsy / `??` = nullish | humane の `//` を JS `??`（nullish）に寄せる（H1） | [humane] | roadmap 3 |
| Array/Object メソッド名 | jq builtin への **JS 名 alias**: `filter`(=select) `find` `includes` `flatMap` `at` `slice` `some`(=any) `every`(=all) `entries`(=to_entries) `keys`(=keys_unsorted) | [追加] | roadmap 4 |
| String メソッド名 | `trim` `toUpperCase`/`toLowerCase` `startsWith` `endsWith` `padStart` `replace`(=sub/gsub) `split` | [追加] | roadmap 6 |
| `typeof` | `type` の JS 名 alias | [追加] | roadmap 4 |
| `jig explain` の JS 等価 | filter の **おおよその JavaScript 等価**を表示（`.users[] \| .name` → `input.users.map(x => x.name)`）。JS/TS native への学習ブリッジ | [追加] | **実装済み (v0)** |

> 方針: jq 名（`select` `to_entries` …）を正、JS 名はその alias として両方
> 受理する（jq スクリプト互換を壊さず、JS 利用者の発見性を上げる）。
> conformance は jq 名で測る。

## 代替ツール survey からの設計アイデア（additive）

GitHub `json` topic + 代替ツール（fx / gron / JSONata / JMESPath / dasel /
yq / jnv / jless / nushell …）の調査で抽出した、**jq 互換を壊さない**追加
アイデア。区分は [追加]=両モード / [humane]=opt-in。

| アイデア | 由来 | コスト | 区分 |
|---|---|---|---|
| **`--js` ECMAScript 式モード**（`x`/`this` = 入力、`jig --js '.users.map(u=>u.name)'`）。JavaScriptCore (`JSContext`) は macOS SDK 同梱なので **追加依存ゼロ**。JS/TS native に最大の価値 | fx, jello | 大 | [humane] |
| **`--gron` / `--ungron`** flatten（`json.a[0] = "x";` 形式で grep/diff 可能、array index の null 埋めで round-trip） | gron | 小〜中 | [追加] |
| **path 付きエラー**（`.users[3].roles` が null、の形で失敗した入力パスを表示） | jq pain #1, gojq | 中 | [追加]（診断基盤の延長） |
| `--yaml` / `--toml` I/O（同じ engine で config を扱う） | gojq, yq, dasel | 中 | [追加] |
| JSONata 風 builtin（`avg` / `group_by_key` / `order_by(f;"desc")` / `~>` chain = `thru`） | JSONata, JMESPath | 小〜中 | [追加] |
| in-place 編集（`-i` write-back + `set` / `del` over path） | dasel, yq | 中 | [追加] |
| 再帰降下 / filter projection sugar（`..key`, `[?(.age>30)]`） | JSONPath, JMESPath | 中 | [humane]（`..` は jq と衝突） |
| TUI explorer（`jig -i`: tree view + live filter + path 補完） | jnv, fx, jless | 大 | [humane]（別 surface） |

> 最有力 3 つ: **path 付きエラー**（日次価値・低リスク、診断基盤の延長）、
> **`--gron`**（小コストで explorer 化）、**`--js`**（JS native への独自
> 価値、JavaScriptCore で依存ゼロ）。
>
> 参考実装: **gojq**（最も読みやすい full 再実装）、**jaq**（定義された
> jq semantics・数値保存）、**gron**（flatten/round-trip アルゴリズム）。

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
