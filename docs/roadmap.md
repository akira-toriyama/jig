# jig roadmap — 人に優しい JSON 操作 CLI

> **モットー: JSON を CLI から操作しやすく。**
> jig は jq の **完全互換を追わない**（厳密互換は jq / gojq / jaq の仕事）。
> jq からは「**JSON + CLI**」の概念だけを受け継ぎ、ECMAScript / lodash・
> es-toolkit のエルゴノミクスと**人に優しい診断**で、CLI から JSON を扱う
> 体験を最良にする。

このドキュメントが **方向性の正本**。2026-06-13 の方針転換でこちらが
[docs/jq-compat.md](jq-compat.md) の「厳密 jq 互換契約」を **置き換える**
（jq-compat.md の差分カタログ・診断哲学は参考資料として残す）。

---

## 現在地（2026-06-13 時点）

**実装済み (v0)**:

- コア: `.` `.foo` `.foo?` `.[N]` `.[]` `|` `,` `(…)`・`#` コメント・`-c`/`-r`/`-n`・stream 入力・number literal 保存・**humane 診断基盤**（span + 型名 + hint + caret）・`jig explain`（JS 等価つき）・`jig check`
- リテラル / 演算子: scalar literals・算術 `+ - * / %`・比較 `== != < <= > >=`・論理 `and`/`or`・単項マイナス・`//`/`??`
- 構築 / 補間: object/array construction `{a:.b}` `[.x]`（短縮形・計算キー）・**文字列補間 `\(…)` / `${…}`**（PR #10, step 2 完了）
- builtin 第1波: `length keys keys_unsorted type(typeof) not reverse add empty map(f) select(f)(filter) has(k)`

**この方針転換で決まったこと**（実装は次セッション以降）: ↓ §1〜§5。

---

## 1. ポジショニング（方針転換）

- jig = **人に優しい JSON 操作 CLI**。jq drop-in ではない（`alias jq=jig` は売り文句から降ろす — jq に慣れていれば即わかる、程度）。
- **jq 負債ゼロ**。厳密バイト互換は追わない。互換は「**よく使う jq をカバー + 差分を crisp に列挙 + 堅い docs/テスト**」。
- **テスト哲学**: 「jq とバイト一致」でなく「**jig 自身が定義した仕様への golden**」を検証。jq はオラクル契約でなく参考・サニティ。
- **破壊的変更 / リファクタ OK**。
- 既存の差別化＝**humane 診断**は最大の武器として強化する。
- number literal 保存（`1e10` を保つ）は jq の dtoa 正規化との乖離だが、**“数字が壊れない機能”として残す**（バグでなく仕様。dtoa バイト一致 PR は不要化）。

---

## 2. パイプ & 言語モデル（確定）

> **一つの `|`、一つの `.`、一つのストリーム。新規性はパイプでなく診断に全振り。JS は文法でなく“語彙”で入れる。**

敵対的設計パネル（4哲学を独立提案 → 3審査 → 統合）で決定。審査 **3/3 が
Unix純パイプを選出**（Claude+CLI 重み・Unix 重みの双方で一致＝堅い結論）。

| 軸 | 確定 |
|---|---|
| **合成** | `\|` のみ正典（＝現エンジン `.pipe`/flatMap）。`.a.b` 連鎖は維持（＝`.a \| .b`） |
| **トピック** | 暗黙 `.`（`.field`/`.[]`/`.[N]`）。builtin 引数は **素のフィルタ** `map(.name)` `select(.active)` |
| **ストリーム** | jq generator 維持（NDJSON・遅延）。`,` は降格：レコード組立は `{…}`、ストリーム収集は `[ … ]` |
| **JS 親和** | **名前だけ**。alias は唯一の正典形に**可逆**で `jig fmt` / `explain --canonical` が正規化 → 「一つの明白な道」を保ちつつ LLM を既知の prior に矯正 |
| **後回し/任意（js-like ④最下位）** | `\|>`（やるなら `\|` の素エイリアス。Hack-pipe の `%` トピックは剰余 `%` と衝突で**不可**）・メソッド鎖（後で可逆 parse-sugar）・アロー `u=>…`（変数束縛が要る＝後） |

**重み付け（実装で迷ったときの優先順）**: Unix 美学 > Claude フレンドリー > 予測しやすさ > js-like。

確定文法での5タスク（✅=今動く / ◻=Wave2 待ち）:

```sh
✅ .users[] | select(.active) | .name              # JS名: filter(.active)
◻ .orders | group_by(.region) | map({region: .[0].region, count: length})
◻ .items | sort_by(.score) | reverse | .[0:3]
✅ .users[] | {id, name}                            # JS名: pick("id";"name")
✅ [.orders[].total] | add                          # JS名: .orders | sumBy(.total)
```

**カノニカル vs エイリアスの規律**: docs / `explain` / `fmt` が出すのは正典形のみ。
エイリアス（`|>`・lodash 名・将来のメソッド鎖）は parse して走るが `fmt` で
正典に正規化。**正典に出ない形を docs/explain に載せない**（パースできない
見出しを agent に見せるのが最悪）。

---

## 3. builtin 採用カタログ（lodash / es-toolkit サーベイ由来）

**命名ポリシー（4則）**:

1. jq に綺麗な形がある → **jq 名を正典 + JS 名を alias**（`sum=add`, `some=any`, `sortBy=sort_by`, `startsWith=startswith`）
2. jq に綺麗な形が無い → **lodash/es-toolkit 名で新規 builtin**（価値の本体）
3. 演算子/構文で足りる → **builtin を作らない**（`+ - * / == < >`, `//`, `??`, `[f,g]`, `{…}`）
4. lodash の挙動が既存 jq builtin と違う → **必ず別名**（黙って再定義しない）。差分は §3 末尾の警告 + jq-compat.md の差分表に記載

参照: [lodash](https://lodash.com/docs/) ・ [es-toolkit](https://es-toolkit.dev/)（モダン・TS ネイティブ。命名は es-toolkit を優先採用してよい）。

<details>
<summary><b>Wave 1（最優先・jq の穴を埋める）</b></summary>

| builtin | 内容 / jq との関係 |
|---|---|
| `reduce` | jq の最難構文 `reduce X as $v (init; update)` ＋ 平易な `reduce(init; f)` 入口。groupBy/countBy/sumBy/uniq の内部基盤 |
| `range` | 唯一欠けているコア **stream** generator（jq の遅延 2,3,4… 維持、lodash の配列にしない）。`[range(0;n)]`/chunk/repeat を解放 |
| `groupBy` | **オブジェクト返し** `{key:[items]}`（人が欲しい形）。jq `group_by` は配列の配列 → **別名**、`group_by` は再定義しない |
| `keyBy` | レコード配列 → `id→record` ルックアップ表。最頻出の join/index、jq では難解（INDEX） |
| `countBy` | `{key:count}` 度数表を1 builtin で。jq の `group_by\|map\|add` の苦行を置換 |
| `sumBy` + `sum` | 射影フィールド合計。jq に sum が**無い** → `map(.x)\|add` が `sumBy(.x)`。`sum` は既存 `add` の alias |
| `mean` + `avg` + `meanBy` | jq に mean/avg が**無い**（`add/length` のゼロ除算地雷）。空入力は **null**（NaN でなく） |
| `pick` | キー部分集合 `pick("a";"b")`。最頻出の object 操作、jq に綺麗形なし（`{a,b}` は静的キーのみ）。path エンジン不要 |
| `omit` | pick の補集合。動的キー一覧での秘匿/ノイズ除去、jq の path-only `del` より良い |
| `min` / `max` | jig にまだ無い（jq にはある）。空は null |
| `minBy` / `maxBy` | 射影キー最小/最大の**要素**（「最安アイテム」「最新注文」）。jq と意味一致 |
| `uniq` / `uniqBy` | **順序保持**の重複除去。jq の `unique` は**ソートする** → **別名**（jq 最大の不満） |
| `trim` / `trimStart` / `trimEnd` | jq 最大の文字列穴：空白 trim が**無い**（部分文字列 ltrimstr/rtrimstr のみ）。scraped/CSV JSON 掃除は日常 |
| `find` | 述語に最初に合う要素（or null）。jq は `first(.[]\|select(f))` を強いる。lazy `first()` と同時に |
| `if/then/elif/else` | jig に分岐構文が**無い**。JSON 整形の核。jq の読みやすい形を採用（lodash `cond` の正体） |

</details>

<details>
<summary><b>Wave 2（強い価値）</b></summary>

`reject`（filter の逆） / `orderBy`（多キー・asc/desc） / `sort_by`+`sortBy`alias+`sort` / `pickBy`・`omitBy`（述語で entry 絞り） / `mapValues`・`mapKeys`（jq with_entries の優しい名） / `flatten`（jq は深い・depth-1 は `flatten(1)`）・`flatMap` / 集合演算 `union`・`intersection`・`difference`（jq は `-` のみ） / `join`（jq と同名） / `chunk`（n 個ずつ） / `compact`（**null のみ**落とす — 0/'' を食わない） / `camelCase`・`snakeCase`・`kebabCase`・`words` / `round(precision)`・`floor(precision)`・`ceil(precision)` / 型述語 `isString`・`isNumber`・`isArray`・`isObject`(JSON object 限定)・`isBoolean`・`isNil`・`isEmpty` / `toNumber`（名は lodash・意味は jq＝位置付きエラー）・`toString`（名は lodash・意味は JSON テキスト） / `matches`（オブジェクト形述語） / `get(path; default)`

</details>

<details>
<summary><b>Wave 3（あると良い / 後で）</b></summary>

`partition` / `findIndex` / `invert`（scalar 限定・object/array 値はエラー） / `values`（**jq の values=drop-null と意図的破壊**） / `zip`・`zipObject`・`fromPairs`・`toPairs`（transpose 基盤） / `clamp` / `capitalize`・`upperFirst`・`lowerFirst`・`startCase` / `truncate(len)` / `repeat` / `deburr`（`stripAccents` 別名検討） / `isFinite`・`isInteger`・`isNaN` / `take`・`drop`・`takeRight`・`head`・`last`・`slice` / `takeWhile`・`dropWhile` / `merge`(=jq `*`)・`assign`(=jq `+`)・`defaults` / `set`・`unset`・`update`（**path エンジン待ち** = roadmap step 5） / `padStart`・`padEnd` / `parseInt`（radix 用） / `unionBy`・`intersectionBy`・`differenceBy` / `findKey` / `xor`

</details>

<details>
<summary><b>JS 名エイリアス（既存 jq builtin の別名・可逆）</b></summary>

`sum=add` ・ `filter=select`(済) ・ `typeof=type`(済) ・ `some=any` ・ `every=all` ・ `sortBy=sort_by` ・ `minBy=min_by` ・ `maxBy=max_by` ・ `avg=mean` ・ `avgBy=meanBy` ・ `toUpperCase=ascii_upcase`(`toUpper` も) ・ `toLowerCase=ascii_downcase`(`toLower` も) ・ `startsWith=startswith` ・ `endsWith=endswith` ・ `replace=gsub`(全置換) ・ `tonumber=toNumber` ・ `tostring=toString` ・ `head=first` ・ `nth=at` ・ `flattenDeep=flatten` ・ `flattenDepth=flatten(d)` ・ `unzip=transpose`・`zip=transpose` ・ `isNull=isNil` ・ `isNaN=isnan` ・ `merge=*` ・ `assign=+` ・ `map_values=mapValues`

</details>

<details>
<summary><b>⚠️ 要・破壊明記の衝突（jq 筋肉記憶を黙って壊さない）</b></summary>

- `groupBy` ≠ jq `group_by`（オブジェクト vs 配列の配列）— 両方を別名で
- `uniq`/`uniqBy` ≠ jq `unique`/`unique_by`（順序保持 vs ソート）— 両方を別名で
- `flatten` 深さ: jq の bare flatten は**深い**、lodash は depth-1。bare は jq の深い既定、depth-1 は `flatten(1)`
- `includes`（フラット/部分文字列）≠ jq `contains`（深い再帰）。`contains` に alias しない
- `compact`: lodash は 0/false/'' も落とす → jig は **null のみ**落とす（数値 JSON で 0 を食わない）
- `replace`: JS/lodash は最初の一致のみ → jig `replace` は**全置換**（`sub`=first / `gsub`=all は残す）
- `entries`=to_entries は `[{key,value}]`、JS の `Object.entries`/`toPairs` は `[[k,v]]` — 形が違う。ペア形は `toPairs`/`fromPairs`
- `merge`(=jq `*`): 配列は**置換**（lodash の index-merge でない）
- `values`: **jq の values=drop-null** と真逆（lodash=値配列）— 意図的破壊として差分表に
- `isObject`: JSON object 限定（lodash の array/function true でない）
- `toString`/`toNumber`: 名は lodash・**意味は jq**（JSON テキスト / 位置付きエラー、silent NaN でない）
- **空集計の出力規律**: `sum`/`min`/`max` → null、`mean`/`avg`/`meanBy` → null（NaN/undefined でなく — JSON を壊さない）

</details>

---

## 4. 診断 & デバッグ性（最大の差別化）

jig の新規性はパイプでなくここに全振りする。

- すべてのエラーは **span + jq 語彙の型名 + hint + caret**。
- **`jig lint`（新規）**: top-level `,` のカルテシアン fan-out（`{x:(.a,.b)}` が無言で2出力する地雷）を「`{…}` か `[…]` のつもり？」と注記。意味論は触らず診断層だけで緩和。
- **`jig fmt`（新規）** / **`jig explain --canonical`**: エイリアス混じりを正典 `|` 形へ正規化 → 「一つの道」を保ち、agent を既知 prior へ矯正。
- `jig explain` の `≈ JS:` ブリッジは JS/TS native・LLM の学習オンランプ。

**🐞 次セッションの起点＝実機検証済みバグ2件（高ROI・エンジン変更ほぼ無し）**:

1. **`=>` 誤誘導ヒント**: `filter(u => u.active)` が「for equality use ==」と誤誘導（パーサが `=` を代入と誤認）。JS ネイティブ/LLM を毎回ミスリード。→ call 引数文脈で `IDENT =>` / `=>` を特別扱いし、humane redirect「jig の builtin は素のフィルタ。`filter(.active)`（要素は暗黙 `.`）。アロー/変数は後（roadmap）」を出す。`FilterParser.swift` の `unexpected` の `"="` 分岐周辺。
2. **`jig explain` の `≈ JS:` 過剰ネスト**: `.[]` の後の `select`/`filter` が `.map(...)` の**内側**に誤ってネスト（`input.users.map(x => x.filter(x => x.active).name)`）。sibling の `.filter(...)` に lower すべき。`Explain.swift` の `jsChain`（`.iterate` 後段の扱い）。JS オンランプを売りにする前に必須。

---

## 5. 実装シーケンス（ROI 順・リレー計画）

1. **バグ① `=>` 誤誘導ヒント修正**（最高ROI・数時間・意味論変更なし）← **次セッションの最初の一歩**
2. **バグ② explain `≈ JS:` の select 過剰ネスト修正**
3. `|>` レキサ・エイリアス（〜3行、`fmt`/render で `|` に正規化）
4. **JS 名エイリアス**追加（`evalCall` の switch、`filter=select`/`typeof=type` と同パターン）
5. **Wave2 builtin で T2/T3 を実走化**: `group_by` `sort_by` ＋ 配列スライス `.[a:b]`（今 `unexpected :`）＋ `to_entries` `range`
6. **`jig lint`**（or explain 拡張）: top-level `,` fan-out 注記
7. （後）メソッド鎖を**可逆 parse-sugar** で（`parseSuffix` を拡張し `.ident(args)` → `pipe(receiver, call)`。`.a.b`→pipe と同じ仕組み）＋ `jig fmt`。**パースできるまで docs に載せない**
8. （別 surface）`--js` アローモード（JavaScriptCore を意味論オラクルに）を隔離 opt-in。正典の「一つの道」に混ぜない

並行: **新ビジョン spec 起草**（このロードマップを土台に、文法=Unix純パイプ / 語彙=採用カタログ / 診断 / デバッグを spec 化）。継続課題: パーサ/評価器の深さ上限（深い再帰で SIGSEGV、docs roadmap「深さ上限 + fuzzing」）。

---

## 6. 作業原則（リレー）

- **1 セッションでの完結を強制しない。リレー形式**で次へ渡す。
- **できない所を暗黙にしない** — 未達・既知バグ・保留は本ドキュメントと PR/メモリに明示。
- **ドキュメントとテストを充実させる**（lodash / es-toolkit を参照）。テストは jig 自身の仕様への golden。
- **ドキュメントが長い場合は `<details>` 折りたたみ**で表現（本ファイルのカタログ参照）。

---

## 7. 設計ヒューリスティック（実装に迷ったら）

1. **歴史で測る（普遍性 = 価値）**: unix と js の歴史を比べれば分かる。**長く普遍なものほど価値が高い**。CLI は今でも**原点にして頂点**。迷ったら長命で普遍な側（Unix のパイプ・テキストストリーム・小さく鋭い道具）を採る。
2. **AI が操作する前提で予測可能に**: Claude Code 等の AI が jig を操作することは十分ありえる。**AI にとっての理解しやすさ・予測のしやすさを最優先**（一つの明白な道・明示 > 暗黙・良いエラーで復帰可能・正典への正規化）。

> 重み付けの正本（§2）: **Unix 美学 > Claude フレンドリー > 予測しやすさ > js-like**。

---

## 8. リレー引き継ぎ

- **済（このセッションまで）**: コア v0 / 演算子(PR #7) / 構築(PR #8) / **文字列補間(PR #10, step 2 完了)** / 本方針転換・パイプ決定・採用カタログの確定（このドキュメント）。
- **次セッションの起点**: §5 の **(1) `=>` 誤誘導ヒント修正** → (2) explain JS ブリッジ修正 → 以降 §5 の順。並行で新ビジョン spec 起草。
- 正本: 方向性は本ファイル。差分カタログ/診断哲学の参考は [docs/jq-compat.md](jq-compat.md)、用語は [docs/glossary.md](glossary.md)、構造/制約/原則は [CLAUDE.md](../CLAUDE.md)。
