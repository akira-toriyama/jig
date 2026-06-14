# 実行プラン — roadmap §5 step 5「Wave1 合成セット」

> **これは「計画セッション（2026-06-14）」の成果物。実行は別セッション。**
> 正本の方向性は [roadmap.md](roadmap.md)（§3 採用カタログ・§5 シーケンス）。
> 本ファイルは step 5 を**着手可能な粒度**に分解し、未決の設計判断を解決したもの。

## スコープ（この step で出すもの）

roadmap §5(5) のちょうど7つに絞る。`countBy`/`keyBy`/`sumBy`/`min`/`max`… は
これらの上に composable に乗るので **次の Wave1 サブステップ**へ（混ぜない）。

| # | 追加 | 種別 | 正典 / alias |
|---|---|---|---|
| 1 | `.[a:b]` 配列・文字列スライス | parser + AST + eval | 構文（builtin でない） |
| 2 | `range` | builtin（generator） | `range`（jq 同名） |
| 3 | `groupBy` | builtin | `groupBy`（**jq `group_by` とは別物**・alias しない） |
| 4 | `mapValues` | builtin | `mapValues` ← jq `map_values`（alias） |
| 5 | `orderBy` | builtin | `orderBy`（Wave1 正典。`sort_by`/`sortBy` alias は Wave2） |
| 6 | `toPairs` | builtin | `toPairs`（`to_entries` とは形が違う・alias しない） |
| 7 | `fromPairs` | builtin | `fromPairs`（同上） |

ゴール（roadmap）: **`.books | groupBy(.genre) | mapValues(length)`** 等の
「小さく重ねる」を E2E 成立させる。`countBy(.g)` ＝ `groupBy(.g) | mapValues(length)`。

---

## 解決済みの設計判断（実行セッションはこれに従えばよい）

<details>
<summary><b>① builtin の引数は <code>;</code> 区切り（コンマでない）— roadmap の例と要reconcile</b></summary>

`FilterParser.parseIdentifierPrimary`（現状）は `f(a; b)` の **`;` 区切り**で引数を取る
（`map(f)`・`has(k)` と同じ）。`f(a, b)` の `,` は **1引数のコンマストリーム**になる。

→ roadmap §2 表の `orderBy(.score, "desc")` は **JS 風の略記**であって、jig の実文法では
`orderBy(.score; "desc")` になる。**決定: `;` 区切りで統一**（全 builtin と一貫・予測可能 §7-2）。
実行時に roadmap §2/§5 の例の `,` を `;` へ直す（or 「例は JS 風」と注記）。**この1点だけ
user 最終確認の価値あり**（コンマを特別扱いして lodash 風にするより `;` 統一を推奨）。
</details>

<details>
<summary><b>② <code>orderBy</code> の多キー・方向グラマー</b></summary>

`;` 区切り前提での確定文法（Wave1）:

- `orderBy(keyFilter)` … 単一キー昇順
- `orderBy(.a; .b; .c)` … 多キー、**全昇順**（先頭キーが優先）
- 末尾引数が**文字列リテラル `"asc"`/`"desc"`** のときは**全キーに適用**する方向指定:
  `orderBy(.score; "desc")` / `orderBy(.a; .b; "desc")`
- **キーごとに別方向**（lodash の `orders` 配列）は **Wave2 以降**（`;` 文法では煩雑）。

判定: 各引数を評価 → 各要素に keyFilter を適用しキー値を得る → jq 全順序（`jqCompare`）で
安定ソート。`"asc"/"desc"` は **キーでなく方向**として末尾でのみ解釈。
キー値が複数出力/空の要素は… **決定: keyFilter の第1出力をキーに**（空ならその要素のキーは
`null` 扱い＝先頭側）。jq `sort_by` と整合。
</details>

<details>
<summary><b>③ <code>groupBy</code> のキー強制と結果形</b></summary>

- 入力は配列。各要素に keyFilter を適用 → **第1出力**をグループキーに。
- 結果は **オブジェクト** `{key: [items...]}`（roadmap = 人が欲しい形・jq `group_by` の配列の配列とは別）。
- **キー強制**: JSON オブジェクトのキーは文字列なので強制が要る。**決定**:
  - `string` → そのまま
  - `number`/`boolean` → compact JSON 文字列（文字列補間の `tostring` と同規則。例 `1`→`"1"`）
  - `null`/`array`/`object` → **humane エラー**（"groupBy key must be a string, number, or boolean — got X"）。
- **キー順**: 初出順（安定。挿入順）。同キーは配列に追記。
- `group_by`（jq 配列返し）は **再定義しない・alias しない**（§3 衝突表）。
</details>

<details>
<summary><b>④ <code>mapValues</code> / <code>toPairs</code> / <code>fromPairs</code></b></summary>

- `mapValues(f)`: object → 各値に f を適用しキー保持。**f の第1出力**で置換。f が空ならその
  キーを**落とす**（jq `.[] |= f` 整合）。配列も可（index 保持で配列返し）。scalar はエラー。
- `toPairs`: object → `[[k,v], ...]`（キー順）。`to_entries` の `[{key,value}]` とは**別形**（alias しない）。非 object はエラー。
- `fromPairs`: `[[k,v], ...]` → object（重複キーは**後勝ち**、初出位置保持＝object 構築と同規則）。
  各要素は2要素配列でキーは文字列必須（でなければ humane エラー）。
</details>

<details>
<summary><b>⑤ <code>range</code>（eager 有限ストリーム）</b></summary>

jig の評価器は eager（`[JigValue]` を返す）なので range も**有限の eager ストリーム**:

- `range(n)` = `0,1,…,n-1` ／ `range(from; to)` ／ `range(from; to; step)`
- step は非ゼロ必須（ゼロは humane エラー）。負 step で下降。
- **暴発ガード**: 生成要素数が上限（例 `10_000_000`）超でエラー（"range too large; 遅延 range は roadmap"）。
  ＝ 現 eager 評価器を OOM から守る。**遅延 generator は別 roadmap 項目**（評価器の lazy 化）。
- 引数は数値（filter 出力）。複数出力はカルテシアン（jq 整合）。非数値はエラー。
</details>

<details>
<summary><b>⑥ <code>.[a:b]</code> スライス（配列・文字列）</b></summary>

- 形: `.[a:b]` `.[a:]` `.[:b]` `.[:]`。負 index は `+count`（jq 整合）。範囲外は clamp。
- **配列**→部分配列、**文字列**→部分文字列（jq は両方スライス可）。それ以外はエラー（`?` で抑制可）。
- `a > b` 等で空 → 空配列/空文字列。`null` 入力 → `null`（伝播）。
- AST: 新ノード `case slice(low: Int?, high: Int?, optional: Bool, span: SourceSpan)`。
</details>

---

## ファイル別 実装プラン（着手順）

> 各ステップは **build green を保つ**こと。XCTest はローカル不可（full Xcode 必要）＝
> `swift build` + 実機バイナリ smoke で検証、**XCTest は CI（PR の `build` job）が正**。
> 既存の検証パターン: 実機バイナリで挙動確認 → golden を XCTest に追加。

### A. `.[a:b]` スライス（独立・最初に）
1. **AST** [Filter.swift](Filter.swift): `slice(low:high:optional:span:)` ケース追加。
2. **Parser** [FilterParser.swift](FilterParser.swift) `parseSuffix()` の `case "["`（~650行）:
   `]` チェック後、`scanInt()` で **optional** low → `skipWhitespace` → `:` なら slice
   （optional high を `scanInt`、`]` 要求、`.slice`）／`:` でなければ従来 index（low 必須）。
   `.[:b]`（low 無し→ `scanInt` が nil でも `:` を見る）も通すこと。
3. **Eval** [Evaluator.swift](Evaluator.swift): `.slice` ケース。array/string を jq 規則で切る
   （負→+count、clamp、low>high→空）。`null`→`null`、その他は `optional` で `[]` or エラー。
4. **Explain** [Explain.swift](Explain.swift): `phrase`/`render`/`jsChain`/`containsIterate` に `.slice`。
   JS 等価 = `subject.slice(a, b)`。`render` = `.[a:b]`（再パース一致）。
5. **Tests**: 新 `SliceTests.swift`（array/string/負/範囲外/`.[a:]`/`.[:b]`/null/optional/render/JS）。

### B. `range`（独立・builtin）
1. **evalCall** [Builtins.swift](Builtins.swift): `("range", 1|2|3)`。引数評価→カルテシアン→
   有限ストリーム生成（step ガード・上限ガード）。
2. **jsCall** [Explain.swift](Explain.swift): best-effort（`Array.from(...)` 等 or `/* range */`）。
3. **Tests**: BuiltinsTests に range（1/2/3引数・負 step・ゼロ step エラー・非数値エラー）。

### C. `groupBy` + `mapValues` + `toPairs` + `fromPairs`
1. **evalCall**: 4ケース追加。groupBy のキー強制ヘルパ（③）を Builtins.swift に。
2. **canonicalBuiltinName** [Explain.swift](Explain.swift): `map_values → mapValues` を追加
   （groupBy/toPairs/fromPairs は jq 別名を持たないので追加不要）。
3. **jsCall**: `groupBy`→`Object.groupBy(...)`、`mapValues`→`Object.fromEntries(Object.entries(x).map(...))`
   等の best-effort、`toPairs`→`Object.entries`、`fromPairs`→`Object.fromEntries`。
4. **error hint** [Builtins.swift](Builtins.swift): 「implemented builtins」一覧に4つ追加。
5. **Tests**: BuiltinsTests に各 builtin ＋ **合成 E2E**（`groupBy(.g) | mapValues(length)` = countBy 相当・
   `groupBy | toPairs` 往復）。golden は jig 仕様（jq オラクルでない）。

### D. `orderBy`（②のグラマー）
1. **evalCall**: 可変長引数。末尾 `"asc"/"desc"` 判定 → key-filters を残す → 安定多キーソート
   （`jqCompare` 利用、`reverse` で desc）。
2. **jsCall**: best-effort（`[...x].sort(...)`）。
3. **Tests**: 単一/多キー/desc/安定性/空・非配列エラー。

### E. docs / 仕上げ
- [README.md](../README.md) / [README.ja.md](../README.ja.md) の builtin 一覧に
  `range groupBy mapValues orderBy toPairs fromPairs` ＋ `.[a:b]` を追加（正典名で）。
- `--help`（[Main.swift](../Sources/JigApp/Main.swift)）の FILTER/BUILTINS ブロック更新。
- [glossary.md](glossary.md) に必要なら groupBy(≠group_by)/orderBy 等の term。
- [roadmap.md](roadmap.md) §5(5) を ✅、§8 引き継ぎ更新、§2 例の `,`→`;` 修正（①）。
- sample/orders.json は `category` 付き配列（`groupBy(.category)` 映え）。他に欲しければ足す。

---

## 衝突・破壊明記（roadmap §3 衝突表より・テストで固定）

- `groupBy` ≠ jq `group_by`（object vs 配列の配列）
- `toPairs`/`fromPairs`（`[[k,v]]`）≠ `to_entries`/`from_entries`（`[{key,value}]`）
- `range` は eager 有限（jq の遅延無限とは違う・上限ガード有り）
- `orderBy` 多キーは全キー同方向のみ（per-key 方向は Wave2）

## リスク / 注意

- **`;` vs `,`**（①）= 唯一の要 user 確認ポイント。実装前に reconcile。
- **eager range の OOM**（⑤ ガードで対処）。評価器の lazy 化は別 roadmap（深さ上限 + fuzzing と同枠）。
- **mapValues の空出力でキー削除**（jq `|=` 整合）は直感に反しうる → テストとコメントで固定。
- 全変更 build green 維持・各 builtin は実機バイナリで先に挙動確認してから golden 化。
- マージ動線: 前回同様 push → PR → **CI `build`(swift test) green** → squash-merge（リポ慣習）。

## サイズ感

A〜E は独立性が高い（A/B は完全独立、C/D は evalCall 追加のみ）。1セッションで全部 or
A+B+C を1 PR・D+E を別 PR でも可。**実行セッションの最初の一歩 = A（スライス）**
（parser/eval/explain/test の一周が小さく、土地勘の再獲得に最適）。
