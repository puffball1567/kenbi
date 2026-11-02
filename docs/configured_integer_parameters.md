# 整数の値渡し引数のストレージ追跡

`source-integer-parameter-storage.c.v1` は、既存のint引数のストレージ追跡を
bool、char、短整数、長整数、符号なし整数、列挙型へ広げる。
Clangのcanonical typeを使い、typedef経由でも同じ規則を適用する。

値渡し引数には呼び出し先固有の起源を作り、Clangの型サイズ・保証配置と
const権限を付ける。&引数の容量・整列要求、直接アクセス、符号なし更新、
非同期借用を既存の解析で照合する。関数復帰時にはその起源の寿命を終了し、
借用が残ればBORROW_OUTLIVES_BUFFERとする。

呼び出し元のconst値を可変の仮引数へコピーしても、仮引数をreadonlyにしない。
逆にconst仮引数へのwriteは拒否する。別名・可視ヘルパー・別翻訳単位でも
仮引数自身の領域を追跡する。

数値のzero/nonzero推論はintの既存対応範囲のまま。
例えばintの256をunsigned charへ渡すと0になり得るため、呼び出し元の
nonzeroという事実を新たに対応した型へそのまま移さない。
容量も実引数の型ではなく変換後の仮引数型から取得する。

浮動小数点、構造体の値渡し、一般の整数値域や変換後の値の証明は未対応。
パラメータ属性・境界式による実行処理の未対応判定も維持する。

回帰: `python3 tests/run_tests_integer_parameters.py`。
`tests/c/t267_integer_parameters.c` と追加C/JSONは独自作成。外部コード・仕様・依存追加なし。
