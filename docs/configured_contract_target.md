# 外付け契約のターゲット照合

2026-09-20。`source-contract-target.v1` を実装。
contracts / protocols パッケージの任意の `target` で、解析対象のターゲットを要求できる。

```json
{"target": {"triple": "x86_64-unknown-linux-gnu", "pointerWidth": 64}}
```

triple は Clang が正規化して返すターゲットトリプル文字列と完全一致で照合する。
pointerWidth はビット単位、1〜65536の整数。両フィールドを必須とし、未知キー・不正型・
空文字・範囲外を拒否する。数値の範囲内であるだけで実在・対応ターゲットと認めるわけではない。
要求は実際の翻訳単位の観測値と一致する必要がある。

`clang_getTranslationUnitTargetInfo` から、解析した翻訳単位ごとのトリプルとポインタ幅を取得する。
ホストのポインタサイズや引数文字列だけから推測しない。`--target` や `-m32` 等を反映した結果と
照合し、同じポインタ幅の別アーキテクチャも拒否する。情報が取得できない場合、要求を満たしたと扱わない。
デフォルトターゲットも実際の観測値を記録する。

全翻訳単位・採用パッケージの要求を確認する。相互に異なる要求は競合として拒否し、
extendsで要求を消さない。compilation（完全な引数列等）やartifacts（内容ハッシュ）とも併用できる。
このtargetはコンパイル引数を変更する設定ではなく、すでに選択された解析条件への検証要求である。

条件不一致・情報欠落は `SAFETY_INPUT_ERROR`、status=unverified、accepted=false、終了コード2。
不一致時は要求したトリプル/幅と観測値をメッセージに含める。
一致しても外部APIの動作契約は引き続き明示された外部前提であり、結果をverifiedへ昇格させない。

JSONのcompilation[].targetに観測した triple / pointerWidth / unit="bits" を記録する。
情報が得られない場合はnull。契約がtargetを指定していなくても観測値は記録する。
contractTargetsにはパッケージ・宣言版・契約ファイル・requiredTriple / requiredPointerWidth・
単位・checkedSourcesを記録する。未指定パッケージのターゲット互換性は推定しない。

これはターゲット識別と標準ポインタ幅の照合。完全なABIの証明ではない。
型ごとのレイアウト、エンディアン、呼び出し規約、アドレス空間別のポインタ幅、CPU機能、
外部ライブラリの実バイナリやリンク実体は別の継続課題。既存の容量・整列解析は引き続き
Clangの各型レイアウトAPIを使用する。ターゲットCPU時間モデルやDMA領域の検証ではない。

独自のC/JSONで tests/run_tests_target.py と tests/c/t257_contract_target.c を検査する。
既存libclang APIを使用し、外部コード・仕様・新規依存の取り込みはない。
