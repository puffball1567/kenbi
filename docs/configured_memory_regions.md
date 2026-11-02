# メモリ領域と借用の配置要求

2026-09-30。`source-memory-regions.c.v1` を実装。
非同期借用（DMA 転送など）が、借用する記憶域の置かれた領域に性質を要求できる。
「DMA エンジンが到達できる領域にあること」が代表例。領域・性質・配置はすべて宣言で与え、
kenbi は推測で配置を決めない。

## 領域の定義

契約（`kind: "contracts"`）またはプロトコル（`kind: "protocols"`）文書の `regions` で定義する。
ボードのメモリマップを独立した文書（`functions: []` の契約文書）に置いてもよい。

```json
"regions": [
  {"id": "sram", "properties": ["dma"]},
  {"id": "dtcm", "properties": []}
]
```

- `properties` は必須（空配列可）。性質の名前は汎用の文字列で、kenbi は特定の名前の意味を持たない。
- 同じ id の定義が複数文書にある場合、性質の集合が同一なら一つの定義、異なれば設定エラー。

## 配置の宣言

- 自動変数（ローカル変数・値引数の記憶域）: プロジェクトの `"placement": {"automatic": "dtcm"}`。
  継承（`extends`）で異なる値を与えると設定エラー。
- 確保契約の結果: `allocates.region`（[確保契約](configured_allocation.md)）。
  確保物の途中を指すポインタも同じ領域。

未定義の領域名は設定エラー（`unknown region 'X'`）。

## 要求と判定

プロトコルの `borrow` に `requireRegion: ["dma"]` を指定すると、借用開始時に判定する。

- 記憶域の配置が宣言されていない（自動変数で `placement.automatic` が無い、確保契約に
  `region` が無い）: `UNKNOWN_BORROW_REGION`（未検証）。
- 配置された領域が要求の性質を一つでも欠く: `BORROW_REGION_REQUIREMENT`（違反）。
- すべて持つ: 検証済み。

どの宣言済み領域も持たない性質を要求すると設定エラー（綴り誤りで永久に満たせない要求を防ぐ）。
`requireRegion` は空にできない。

各 obligation の `borrowRegion` と診断の `regionRequirement` に、要求した性質・記憶域の種類
（automatic / allocation）・確保関数・領域・領域定義と配置宣言の出典・欠けた性質・判定を記録する。
レポートの `regionDefinitions` と `placement` に使用した定義と配置の出典を列挙する。

領域の性質そのもの（本当に DMA が到達できるか）はボード・デバイスの前提であり、
注釈だけで verified へ昇格しない。

## 対象外

グローバル・static 変数の配置（リンカのセクション割り当て）、領域境界をまたぐ記憶域、
アドレス値からの領域判定、借用以外の外部アクセス契約への領域要求。

## DMA 受け入れ例

`demo/dma/device-c.*` は、デバイス A に `requireRegion: ["dma"]` を加え、スタックを DMA の
届かない `dtcm` に置いたボード（`demo/dma/board.contracts.json`）での検査。スタック上の
バッファを渡す行は最初の転送開始で領域違反になり、`malloc`（`sram` に配置と宣言）の
バッファを使う `heap_tx_normal` は受理、`free_during_tx` は転送中の解放を違反として報告する。
期待結果は `tests/run_tests_dma_acceptance.py` で3デバイス分を固定している。

## 回帰

`tests/c/t299_memory_regions.c` と `tests/run_tests_regions.py`（34件）。
独自作成の入力のみ。外部コード・仕様・依存の追加はない。
