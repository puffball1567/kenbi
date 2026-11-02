# 実行時間の上限（外部の WCET 証拠）

2026-10-03。`external-execution-time.v1` を実装。
kenbi は実行時間を自分では解析しない。外部の WCET 解析ツールが出した上限を取り込み、
解析したビルドに結び付けたうえで、プロファイルの `maxExecutionTime` と照合する。
計測値は上限の証拠として扱わない。

## 証拠文書

プロジェクトの `timing` に `kind: "timing"` の文書を列挙する。

```json
{
  "schemaVersion": 1, "kind": "timing", "id": "board.timing", "version": "1",
  "assumption": "wcet.analysis",
  "artifact": {"path": "build/firmware.elf", "sha1": "9C1E..."},
  "sources": [{"path": "src/isr.c", "sha1": "41AB..."}],
  "functions": [
    {"source": "src/isr.c", "name": "dma_irq_handler", "value": 900, "unit": "cycles",
     "method": "static-analysis", "tool": "wcet-analyzer 3.2"},
    {"source": "src/isr.c", "name": "dma_irq_handler", "value": 410, "unit": "cycles",
     "method": "measurement", "tool": "trace capture"}
  ]
}
```

- `assumption`（必須）: ツールの上限が正しいという外部前提。満たした上限はこの前提付きの conditional。
- `artifact`（必須）: ツールが解析したバイナリとその SHA-1。現在のファイルと一致しない、または
  存在しない場合、その文書の上限はすべて使えない。
- `sources`: ビルドに使ったソースとその SHA-1。一致しなければ同様に使えない。
- `functions`: 関数（ソースと名前で特定）ごとの値。`value` は呼び出し先を含む関数全体の値。
  `unit` は `cycles` か `ns`、`method` は `static-analysis`（上限）か `measurement`（計測値）。

## 判定

プロファイルの `"maxExecutionTime": {"value": 1000, "unit": "cycles"}` と照合する
（`extends` で複数指定された場合は小さい方。単位が異なれば設定エラー）。

- 使える上限（静的解析・ビルドに一致・同じ単位）のうち最小のものが制限を超える:
  `EXECUTION_TIME_EXCEEDED`（違反）。以下なら前提付きで受理。
- 計測値しかない: `MEASUREMENT_IS_NOT_A_BOUND`（未検証）。計測は最悪時を示さない。
- 証拠が無い: `MISSING_TIMING_EVIDENCE`（未検証）。
- 古い証拠・単位の不一致など、使える上限が無い: `UNKNOWN_EXECUTION_TIME`（未検証）。
  単位は換算しない（クロック周波数を推測しない）。

各 obligation の `executionTime` に、制限・採用した上限・参照したすべての証拠（古いものはその理由付き）を記録する。

## 対象外

割り込み・プリエンプションによる遅延、応答時間解析、呼び出し先の上限からの合成、
kenbi 自身による実行時間の解析。

## 回帰

`tests/c/t303_execution_time.c` と `tests/run_tests_execution_time.py`（24件）。
解析対象のバイナリはテストが書く代用ファイルで、その SHA-1 への結び付けを検査する。
