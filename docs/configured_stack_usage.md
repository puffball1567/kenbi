# スタック使用量の上限

2026-10-03。`source-stack-usage.c.v1` を実装。
コンパイラのスタック使用量レポート（`-fstack-usage` の `.su`）から各関数のフレームサイズを取り込み、
kenbi の呼び出しグラフ上で最悪経路の合計を求めて、プロファイルの `maxStackBytes` と照合する。
フレームサイズはコンパイラの申告であり、外部前提（conditional）として扱う。

## 証拠文書

プロジェクトの `stackUsage` に `kind: "stackUsage"` の文書を列挙する。

```json
{
  "schemaVersion": 1, "kind": "stackUsage", "id": "board.stack", "version": "1",
  "assumption": "gcc.stack-usage",
  "perCallBytes": 0,
  "reports": [
    {"path": "build/driver.su", "format": "gcc", "source": "src/driver.c",
     "sourceSha1": "3F2A..."}
  ]
}
```

- `assumption`（必須）: レポートの数値が実際のビルドのフレームを上から抑えるという前提。
- `perCallBytes`（必須）: レポートのフレームに含まれず、呼び出しごとに加わるスタック（0〜4096）。
  GCC の x86-64 の値は戻りアドレスを含む。どの値が正しいかはツールとターゲットに依存するため、
  推測せず宣言させる。
- `format`: `gcc`（`file:line:column:name`）または `clang`（`file:line:name`）。自動判定はしない。
- `source` と `sourceSha1`: レポートを作ったソースとその SHA-1。現在のソースのハッシュと異なれば、
  そのファイルの関数はすべて `STALE_STACK_EVIDENCE`（未検証）。レポート自体のハッシュは `inputs` に記録する。

各行は関数名の位置（ファイル・行・名前）で、解析した関数の定義に一対一で対応付ける。
戻り値型と関数名を別の行に書いた定義も、名前の行で対応する。
行の形式違反、別ファイルの項目、未知の修飾子、重複は設定エラー（終了コード2）。
修飾子 `static` と `dynamic,bounded` はその値を上限とし、`dynamic` は上限なしとする。

外部関数（本体を解析しない関数）は、契約の `maxStackBytes`（呼び出し先を含む使用量）で上限を宣言する。

## 計算と判定

関数の使用量 = 自分のフレーム + `perCallBytes` + 呼び出し先の使用量の最大値。

- 合計がプロファイルの `maxStackBytes` を超える: `STACK_LIMIT_EXCEEDED`（違反）。
- 上限が確立できない場合は未検証:
  - 再帰（`RECURSIVE_STACK_USAGE`）
  - 関数ポインタ等の未解決の呼び出し（`UNRESOLVED_STACK_USAGE`）
  - `dynamic` フレーム（`DYNAMIC_STACK_FRAME`）
  - レポートに無い関数（`MISSING_STACK_EVIDENCE`）
  - 古いレポート（`STALE_STACK_EVIDENCE`）
  - 上限の無い外部関数（`MISSING_STACK_CONTRACT`）
  - 暗黙の呼び出しを含む関数（`UNSUPPORTED_STACK_USAGE`）
- `extends` で複数指定された `maxStackBytes` は小さい方を適用する。

各 obligation の `stackUsage` に、上限・計算結果・最悪経路・使用したフレームとレポート・前提を記録する。

## 割り込みによる上乗せ（2026-10-04）

プロジェクトの `interrupts` で、検査対象を割り込み得るハンドラとネストの仕方を宣言すると、
すべてのスタック上限にハンドラの使用量を加える。宣言が無ければ割り込みについて何も仮定しない。

```json
"interrupts": {
  "nesting": "by-priority",
  "entryBytes": 32,
  "handlers": [{"symbol": "c:@F@uart_isr", "priority": 1}, {"symbol": "c:@F@timer_isr", "priority": 3}]
}
```

- `nesting`: `by-priority`（優先度が大きいハンドラが小さいハンドラを割り込む）または `none`（ネストしない）。
- `entryBytes`: ハンドラに入るたびにハードウェアが積むスタック（0〜4096）。推測せず宣言させる。
- ハンドラの使用量 = そのハンドラ自身の上限（上記の計算）+ `entryBytes`。
- 通常の関数: `by-priority` では優先度が厳密に上がっていくハンドラの連鎖のうち合計最大のもの、
  `none` では最大のハンドラ1つを加える。同じ優先度は互いにネストしない。
- ハンドラ自身の上限: `by-priority` ではそれより高い優先度のハンドラの連鎖を加え、`none` では加えない
  （自分の `entryBytes` は自分の上限に含めない）。
- 使用量が確立できないハンドラ（本体もレポートも無い、上限の無い外部関数など）があれば、上限全体が未検証。
- `interrupts` は一度だけ宣言できる（`extends` で重ねると設定エラー）。

obligation の `stackUsage.interrupts` に、ネスト方式・`entryBytes`・上乗せ量・その連鎖・宣言の出典を記録する。

## 対象外

スレッドごとのスタック配分、優先度の動的変更・割り込み禁止区間による上乗せの削減、
alloca、コンパイラが挿入する関数（memcpy 等への暗黙の呼び出し）。
可視本体を持つ関数の契約上の `maxStackBytes` は使わず、本体のレポートで計算する。

## 回帰

`tests/c/t302_stack_usage.c` と `tests/run_tests_stack_usage.py`（43件）。数値はテストが書く合成の
レポートで固定し、インストール済みの GCC が出力した実際のレポートを読み込むケースを1件含む。
