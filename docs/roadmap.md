# jig roadmap — 人に優しい JSON 操作 CLI

> **モットー: JSON を CLI から操作しやすく。**
> jig は **jq 互換を完全に追わない**（jq 互換が要るなら jq / gojq / jaq を使う＝他ツールの仕事）。
> jq からは「**JSON + CLI**」の着想だけを受け継ぎ、語彙・エルゴノミクスは
> **es-toolkit を正典**（modern・TS ネイティブ）に、**人に優しい診断**で
> CLI から JSON を扱う体験を最良にする。

このドキュメントが **方向性の正本**。2026-06-13 の方針転換でこちらが
[docs/jq-compat.md](jq-compat.md) の「厳密 jq 互換契約」を **置き換える**
（jq-compat.md の差分カタログ・診断哲学は参考資料として残す）。

---

## 現在地（2026-06-14 時点）

**実装済み (v0)**:

- コア: `.` `.foo` `.foo?` `.[N]` `.[]`（null → **空ストリーム** / 非 null scalar はエラー）`|` `,` `(…)`・`#` コメント・`-c`/`-r`/`-n`・stream 入力・number literal 保存・**humane 診断基盤**（span + 型名 + hint + caret）・`jig explain`（JS 等価つき）・`jig check`
- リテラル / 演算子: scalar literals・算術 `+ - * / %`・比較 `== != < <= > >=`・論理 `and`/`or`・単項マイナス・`//`（false+null を落とす）・`??`（nullish ＝ null のみ落とす）
- 構築 / 補間: object/array construction `{a:.b}` `[.x]`（短縮形・計算キー）・**文字列補間 `\(…)` / `${…}`**（PR #10, step 2 完了）
- builtin 第1波（**正典＝es-toolkit 名**）: `length keys keys_unsorted typeof not reverse sum empty map(f) filter(f) has(k)`（jq 名 `type` / `add` / `select` は alias として受理）

**2026-06-14 クリーンアップ＆再ポジショニング・セッション = §5 step 1〜4 完了**: バグ①② 修正・**dual-mode 撤去（意味論ひとつ）**・**jq 互換負債の一掃**・**es-toolkit 正典化（typeof/filter/sum）**。詳細は §5・§8。残りの方針転換実装（Wave1 builtin・補完エンジン…）は §1〜§5 / 次セッション以降。

---

## 1. ポジショニング（方針転換）

- jig = **人に優しい JSON 操作 CLI**。**jq 互換は完全に追わない**（2026-06-13 user 決定。jq 互換が要るなら jq / gojq / jaq を使う＝他ツールの仕事）。jq からは「JSON + CLI」の**着想だけ**を受け継ぐ。「よく使う jq をカバー」という互換ゴール自体を**撤去**。
- **モードは1つ**。`--humane` / `JIG_MODE` / `# jig:humane` pragma の **dual-mode は廃止**（「jq モード」は無い）。意味論は jig の流儀ひとつに統一。
- **語彙は es-toolkit を正典**（modern と感じる方を採る）。jq 名は alias か廃止。既に alias の `filter`(=select) / `typeof`(=type) は**正典へ昇格**。命名規則は §3（2026-06-13 改定）。
- **テスト哲学**: 「jq とバイト一致」でなく「**jig 自身の仕様への golden**」。jq はオラクルでなく歴史的参考。
- **破壊的変更 / リファクタ OK**。差別化＝**humane 診断**を最大の武器に強化（§4。**補完・予測**もこの延長）。
- number literal 保存（`1e10` を保つ）は **“数字が壊れない機能”として残す**（バグでなく仕様。dtoa バイト一致 PR は不要化）。
- **撤去待ち（実装リレー・§5/§8）**: `--humane` フラグ実体 / README の dual-mode 節 / `--help` の "jq-compatible" 表記 / `docs/jq-compat.md` は **SUPERSEDED** → 撤去・es-toolkit 方針へ更新。

### 入力フォーマット — 寛容な入力（JSONC / JSON5）｜**最終ゴール・優先度低**

最終ゴールに **JSONC / JSON5 入力の受理**を加える（near ROI 順 §5 には割り込ませない、当面後回し）。
根拠は Unix の **「入力に寛容・出力に厳格」**（Postel 則／§7-1 の普遍性ヒューリスティック）—
現実の JSON（`tsconfig.json` / `devcontainer.json` / VS Code `settings.json` …）はコメントや
末尾カンマを含み、「**JSON を CLI から操作しやすく**」を名乗る以上それらを黙って読めるべき。
`comment-json` / JSON5 を当然に扱う npm/JS エコシステム親和とも一致する。

**確定方針**:

- **入力のみ拡張、出力は厳格 JSON のまま**。正典は一つ＝「一つの明白な道」を崩さない。
  strict JSON は両者の部分集合なので、寛容化で既存の妥当入力が壊れることはない（非破壊）。
- **段階と既定**: ① **JSONC**（`//` `/* */` コメント＋末尾カンマ）＝**既定で寛容に受理**
  （無害＝strict JSON の superset）。② **JSON5**（無引用キー・単引用符・hex・`Infinity`/`NaN`
  等のフル superset）＝**`--json5` opt-in**（緩いトークンは typo を隠すため既定にしない）。
  近接ゴールは JSONC、JSON5 はストレッチ。
- **`Infinity` / `NaN`（JSON5）の出力**: 入力では受理するが、**出力時に humane エラー**
  （JSON に表現不可。silent な `null`/`NaN` 破壊はしない）。number-literal 保存方針と一貫。
- **実装の置き場所**: 寛容 JSON リーダは **sill（family 共有 pure module）側**に持つ。
  chord の TOML を sill へ寄せた Phase 1.6 と同じ「四つの自前パーサを一つへ」発想を JSON
  入力系にも適用（perch / wand / facet / jig で将来共有化）。

<details>
<summary>実装時に詰める細部</summary>

- **stream / NDJSON 分割（jq generator）とコメント・空白の相互作用** を要検証。
- **診断との整合**: 寛容に受けた箇所（コメント／末尾カンマ除去後）でもエラーの caret が
  **元バイト位置**を指せるよう span 写像を保つ。
- 厳格モードの明示フラグ（`--json-strict` で寛容受理を切る）の要否は実装時に決める。

</details>

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
✅ .users[] | filter(.active) | .name               # 正典 filter（select は alias）
◻ .orders | groupBy(.region) | mapValues(length)    # = countBy(.region)（オブジェクト返し）
◻ .items | orderBy(.score, "desc") | take(3)         # 多キー orderBy（sort_by/reverse の上位）
✅ .users[] | {id, name}                             # pick("id","name") も同義
◻ .orders | sumBy(.total)                            # 正典（今は [.orders[].total]|add で代替可）
```

**カノニカル vs エイリアスの規律**: docs / `explain` / `fmt` が出すのは正典形のみ。
エイリアス（`|>`・lodash 名・将来のメソッド鎖）は parse して走るが `fmt` で
正典に正規化。**正典に出ない形を docs/explain に載せない**（パースできない
見出しを agent に見せるのが最悪）。

---

## 3. builtin 採用カタログ（lodash / es-toolkit サーベイ由来）

**命名ポリシー（5則・2026-06-13 改定＝es-toolkit 正典化）**:

1. **es-toolkit / JS 名を正典**。同義の jq builtin があれば jq 名は **alias**（または廃止）。例: `filter`(正典)/`select`(alias)、`sum`+`sumBy`(正典)、`orderBy`+`sortBy`(正典)/`sort_by`(alias)、`uniq`/`uniqBy`(正典)/`unique`(alias)、`startsWith`/`endsWith`。
2. es-toolkit にも jq にも無い → **新規 builtin を es-toolkit 流の命名で**（価値の本体）。
3. 演算子/構文で足りる → **builtin を作らない**（`+ - * / == < >`, `//`, `??`, `[f,g]`, `{…}`）。
4. **同名で挙動が分岐する所は黙って変えない** — es-toolkit 意味を採るが、jq 筋肉記憶と衝突する点は §3 末尾の衝突表に明記（`groupBy`≠`group_by` 等）。
5. 純 jq 系で **es-toolkit に対応物が無い**もの（遅延 generator `range`/`empty`/`..`、演算子 `?`/`//`）は jq 系の綴りを残す＝「es-toolkit 対応物が**ある所は** es-toolkit 優先」。

参照: [lodash](https://lodash.com/docs/) ・ [es-toolkit](https://es-toolkit.dev/)（モダン・TS ネイティブ。命名は es-toolkit を優先採用してよい）。

<details>
<summary><b>Wave 1（最優先・jq の穴を埋める）</b></summary>

| builtin | 内容 / jq との関係 |
|---|---|
| `reduce` | jq の最難構文 `reduce X as $v (init; update)` ＋ 平易な `reduce(init; f)` 入口。groupBy/countBy/sumBy/uniq の内部基盤 |
| `range` | 唯一欠けているコア **stream** generator（jq の遅延 2,3,4… 維持、lodash の配列にしない）。`[range(0;n)]`/chunk/repeat を解放 |
| `groupBy` | **オブジェクト返し** `{key:[items]}`（人が欲しい形）。jq `group_by` は配列の配列 → **別名**、`group_by` は再定義しない。下流は ↓ `mapValues`/`orderBy`/`toPairs` で**小さく重ねる**（決定③で合成語彙を Wave1 に格上げ） |
| `mapValues` | オブジェクトの各値に f を適用（キー保持）。**`groupBy` の下流の要**：`groupBy(.g)\|mapValues(length)` = `countBy` 相当、`mapValues(meanBy(.price))` で集計。jq `with_entries` の優しい形 |
| `orderBy` | **多キー・asc/desc** ソート（`orderBy(.score,"desc")`）。`sort_by`/`sortBy` の上位互換で **正典**。`groupBy \| orderBy` の「小さく重ねる」主役 |
| `toPairs` / `fromPairs` | object ⇄ `[[k,v]]`（JS `Object.entries`/`fromEntries`）。オブジェクトを pipe で並べ替え/絞り込みして戻す往復。entries 形 `[{key,value}]`(=to_entries) は別物 |
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

`reject`（filter の逆） / `sort_by`+`sortBy`alias+`sort`（正典 `orderBy` の単キー簡略形 → **`orderBy` は Wave1**） / `pickBy`・`omitBy`（述語で entry 絞り） / `mapKeys`（jq with_entries の優しい名。**`mapValues` は Wave1**） / `flatten`（jq は深い・depth-1 は `flatten(1)`）・`flatMap` / 集合演算 `union`・`intersection`・`difference`（jq は `-` のみ） / `join`（jq と同名） / `chunk`（n 個ずつ） / `compact`（**null のみ**落とす — 0/'' を食わない） / `camelCase`・`snakeCase`・`kebabCase`・`words` / `round(precision)`・`floor(precision)`・`ceil(precision)` / 型述語 `isString`・`isNumber`・`isArray`・`isObject`(JSON object 限定)・`isBoolean`・`isNil`・`isEmpty` / `toNumber`（名は lodash・意味は jq＝位置付きエラー）・`toString`（名は lodash・意味は JSON テキスト） / `matches`（オブジェクト形述語） / `get(path; default)`

</details>

<details>
<summary><b>Wave 3（あると良い / 後で）</b></summary>

`partition` / `findIndex` / `invert`（scalar 限定・object/array 値はエラー） / `values`（**jq の values=drop-null と意図的破壊**） / `zip`・`zipObject`（transpose 基盤。**`toPairs`/`fromPairs` は Wave1**） / `clamp` / `capitalize`・`upperFirst`・`lowerFirst`・`startCase` / `truncate(len)` / `repeat` / `deburr`（`stripAccents` 別名検討） / `isFinite`・`isInteger`・`isNaN` / `take`・`drop`・`takeRight`・`head`・`last`・`slice` / `takeWhile`・`dropWhile` / `merge`(=jq `*`)・`assign`(=jq `+`)・`defaults` / `set`・`unset`・`update`（**path エンジン待ち** = roadmap step 5） / `padStart`・`padEnd` / `parseInt`（radix 用） / `unionBy`・`intersectionBy`・`differenceBy` / `findKey` / `xor`

</details>

<details>
<summary><b>JS / es-toolkit 名 ⇄ jq 名の対応（2026-06-13 改定で <u>左＝正典</u>）</b></summary>

> 改定後は **左（JS/es-toolkit 名）が正典・右（jq 名）が alias**（命名規則①反転）。`filter`/`typeof` は正典へ昇格済。`X=Y` は「**正典 X ← jq の Y**」と読む。

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

### 補完・予測（fish 風）— 診断を「次のトークン」へ拡張（2026-06-13 決定②）

問題: フィルタは**1個のクオート文字列**で渡るのでシェルが中身を補完できない。jig は
**入力データを見られる**のでこれを最大の武器にする（「現在トークンの caret 診断」の自然な拡張＝
「**次トークンの予測**」）。**三層すべてを最終ゴール**に置く（実装順 **B → C → A**）:

- **(B) `jig complete` — スキーマ認識の動的補完エンジン〔真実源〕**: 書きかけフィルタ＋入力を
  渡すと、現在トークンに一致する builtin 候補＋**入力 JSON から読んだ実フィールド名**
  （`.books` の次に `.id .title .price …`）を構造化で返す。シェル補完関数も対話モードも
  これを呼ぶ単一の真実源。**AI からも呼べる**（エージェントが「次の妥当な一手」を発見）＝§7-2 直結。
- **(C) 対話モード — fish 風の薄いヒント〔目玉〕**: フィルタ無しの `jig`（or `jig -i`）で
  REPL/TUI を開き、打ちながら **①結果のライブプレビュー** ＋ **②次の builtin/フィールドの
  ghost テキスト**（淡色インライン）＋ **③インライン humane エラー**。`jnv`/`fx` 系。jig が
  端末描画を握るので ghost を自由に出せる（普通のシェルの fish ghost は履歴ベース＝スキーマ
  認識 ghost はこの自前モードに置くのが筋）。
- **(A) 静的シェル補完**: bash/zsh/fish 用スクリプト（フラグ・サブコマンド）。定番・同梱。

正典規律と一貫: 候補は**正典形のみ**を提案（alias は受理するが提案しない）＝「一つの明白な道」。

**🐞 次セッションの起点＝実機検証済みバグ2件（高ROI・エンジン変更ほぼ無し）**:

1. **`=>` 誤誘導ヒント**: `filter(u => u.active)` が「for equality use ==」と誤誘導（パーサが `=` を代入と誤認）。JS ネイティブ/LLM を毎回ミスリード。→ call 引数文脈で `IDENT =>` / `=>` を特別扱いし、humane redirect「jig の builtin は素のフィルタ。`filter(.active)`（要素は暗黙 `.`）。アロー/変数は後（roadmap）」を出す。`FilterParser.swift` の `unexpected` の `"="` 分岐周辺。
2. **`jig explain` の `≈ JS:` 過剰ネスト**: `.[]` の後の `select`/`filter` が `.map(...)` の**内側**に誤ってネスト（`input.users.map(x => x.filter(x => x.active).name)`）。sibling の `.filter(...)` に lower すべき。`Explain.swift` の `jsChain`（`.iterate` 後段の扱い）。JS オンランプを売りにする前に必須。

---

## 5. 実装シーケンス（ROI 順・リレー計画）

1. ✅ **バグ① `=>` 誤誘導ヒント修正**（done 2026-06-14）: call 引数の `=>` を検出し「bare filter を使え（`filter(.active)`）」へ redirect。`=` 単体は equality hint 維持。
2. ✅ **バグ② explain `≈ JS:` の select 過剰ネスト修正**（done 2026-06-14）: `.[]` 後段を `jsStream()` で lower、select/filter は sibling `.filter(…)` に hoist、projection は `.map`/`.flatMap` に畳む。
3. ✅ **jq-compat / dual-mode 撤去**（done 2026-06-14・決定①）: `Mode.swift` 削除、`--humane`/`JIG_MODE`/`# jig:humane` 撤去、`mode` 引数を evaluate/evalCall/evalLogical/explain から除去しモード1本化。README ×2 / CLAUDE / glossary / help / Package.swift / CONTRIBUTING / PR template / run.sh / homebrew formula を再ポジショニング、`docs/jq-compat.md` は SUPERSEDED バナー付きで保存。**意味論の確定（破壊的・記録）**: ↓ §8 の「2026-06-14 決定」。
4. ✅ **es-toolkit / JS 名を正典化**（done 2026-06-14・決定①の②）: 実装が既にある builtin のみ昇格 ＝ `typeof`(←type) / `filter`(←select) / `sum`(←add)。help・explain step・error hint・`render()`（=fmt の種）は**正典のみ**を提示（`canonicalBuiltinName()` が単一の真実源）。**`sumBy`/`groupBy`/`orderBy`… は実装が未だ無いので step 5 へ**（alias だけ足すと未実装を指す）。
5. **Wave1 合成セットで「小さく重ねる」を E2E 成立**（決定③）← **次セッションの最初の一歩**: `groupBy`(オブジェクト返し) / `mapValues` / `orderBy`(多キー) / `toPairs`・`fromPairs` ＋ 配列スライス `.[a:b]`（今 `unexpected :`）＋ `range`。`countBy` = `groupBy\|mapValues(length)`。正典化パターン（§5-4・`canonicalBuiltinName` + evalCall switch）に乗せる。
6. **補完エンジン `jig complete`（B）**（決定②）: スキーマ認識の動的補完（builtin＋入力の実フィールド名）。**AI 呼び出し可** → **(C) 対話モード**（fish 風 ghost＋ライブプレビュー）→ **(A) 静的補完**同梱。詳細 §4。
7. **`jig lint`**（or explain 拡張）: top-level `,` fan-out 注記
8. `|>` レキサ・エイリアス（〜3行、`fmt`/render で `|` に正規化）
9. （後）メソッド鎖を**可逆 parse-sugar** で（`parseSuffix` を拡張し `.ident(args)` → `pipe(receiver, call)`）＋ `jig fmt`。**パースできるまで docs に載せない**
10. （別 surface）`--js` アローモード（JavaScriptCore を意味論オラクルに）を隔離 opt-in。正典の「一つの道」に混ぜない
11. （**最終ゴール・優先度低／near ROI 順に割り込ませない**）**寛容入力**: JSONC を既定受理 → `--json5` opt-in。入力リーダは sill 共有 pure module 側、出力は厳格 JSON のまま。方針は §1「入力フォーマット」。

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

- **済（〜2026-06-13）**: コア v0 / 演算子(PR #7) / 構築(PR #8) / **文字列補間(PR #10, step 2 完了)** / 方針転換・パイプ決定・採用カタログの確定（roadmap PR #11/#12）。
- **済（2026-06-14 クリーンアップ・セッション ＝ §5 step 1〜4）**: バグ①② 修正・**dual-mode 撤去**（`Mode.swift` 削除・`mode` 引数除去・`--humane`/`JIG_MODE`/pragma 撤去）・**jq 互換負債の一掃**（README ×2 / CLAUDE / glossary / Package.swift / CONTRIBUTING / PR template / run.sh / homebrew / 全コメント）・**es-toolkit 正典化**（typeof/filter/sum・`canonicalBuiltinName`）。`swift build` clean、挙動は実機バイナリで検証（XCTest は full Xcode が要る＝ローカル不可・CI 任せ）。多エージェントの敵対レビューで残債 9 件を検出・全修正。**未 push（ユーザ承認待ち、branch `refactor/drop-jq-debt-canonicalize`）**。
  - **⚠️ 2026-06-14 意味論の確定（破壊的・`破壊的変更OK` 下でユーザ承認可能・要・最終確認）**:
    - **H2**: `.[]` を null に適用 → **常に空ストリーム**（旧 jq モード既定はエラー）。`.foo`/`.[N]` の null 伝播と一貫。非 null scalar は依然エラー（humane hint 付き）。
    - **H1**: `//` は **常に false+null を落とす**（jq 意味論・旧既定と同じ）。旧 humane の「`//` は false を残す」は**撤去**。理由＝`??` が nullish（null のみ）を担うので、`//` と `??` を**別物として維持**（同一化すると冗長）。能力の喪失なし。
- **次セッションの起点**: §5 **(5) Wave1 合成セット**（`groupBy`/`mapValues`/`orderBy`/`toPairs`・`fromPairs` ＋ `.[a:b]` スライス ＋ `range`）。正典化パターン（§5-4）に乗せる。以降 §5 の (6) 補完エンジン `jig complete` → … の順。並行で新ビジョン spec 起草。
- **撤去/更新待ち（決定①の波及）= 完了**: `--humane` 実体・README dual-mode 節・`--help` の "jq-compatible"・`docs/jq-compat.md`（SUPERSEDED 化）・CLAUDE の互換記述、いずれも 2026-06-14 で処理済。
- 正本: 方向性は本ファイル。用語は [docs/glossary.md](glossary.md)、構造/制約/原則は [CLAUDE.md](../CLAUDE.md)。`docs/jq-compat.md` は歴史的参考（SUPERSEDED）。
