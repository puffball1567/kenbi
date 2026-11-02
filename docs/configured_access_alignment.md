# 外部APIアクセスの整列要求

`contracts.functions[].accesses[]` のread/writeに `alignment` を指定できる。
借用の `borrow.alignment` と判定器・設定値の検査を共通化している。

```json
{"symbol":"c:@F@consume","effects":[],"assumption":"api.behavior",
 "accesses":[{"argument":1,"mode":"read","alignment":16,"minBytes":32}]}
```

値は1〜536870912の2の冪。省略時に整列要求を追加しない。
release/relocateへの指定や同じ引数・モードの重複は設定エラー。
`minBytes` と併用でき、`alignment` だけでも順序付き解析を有効にする。
状態機械の選択は不要。既存の禁止効果・文脈・深度等のprofileと併用する。
解析対象の全外部呼び出しに完全なaccesses契約を要求する点、ブロックでは囲む関数の
状態・前提を引き継ぐ点は[容量要求](configured_access_capacity.md)と同じ。

先頭の保証配置A、定数バイトオフセットO、要求Rを照合する。
AがRの倍数でOもRの倍数なら検証済み。Oがgcd(A,R)の倍数でなければ
`MEMORY_ALIGNMENT_REQUIREMENT`（違反）。その他は `UNKNOWN_MEMORY_ALIGNMENT`（未検証）。
動的オフセット・未知の起源も未検証。追跡中の範囲逸脱は `MEMORY_POINTER_RANGE`。
見かけのポインタ型やポインタ変数自身の整列指定で参照先の保証を強めない。

自然な型配置と、直接整数リテラルの `_Alignas` / GNU aligned に対応する。
未対応のマクロ・式・属性は従来どおり未検証。別名、可視ヘルパー、別翻訳単位へ
起源・配置・位置を伝播し、読み取り専用・解放済み・借用競合の検査も維持する。
容量条件を指定した場合は容量検査を先に行うため、そこで停止した経路の整列証拠は空になる。

capabilityは `source-access-alignment.c.v1`。
obligationの `accessAlignment` に要求値・先頭保証・オフセット・判定・契約ファイル・
呼び出し連鎖を記録し、診断の `alignmentRequirement` に同じ証拠を付ける。
不明値はnull、単位はc-sizeof-bytes。外部APIが契約どおり動作することは外部前提であり、
整列成功だけで全体をverifiedに昇格させない。可視本体のメモリ契約適合は引き続き未検証。

この条件は整列のみを要求する。アクセス長やone-pastからの読み書きの安全性は
整列条件だけでは保証しないため、必要な容量をminBytesで別途指定する。
ヒープ配置、物理DMA領域、MMIOアクセス幅、キャッシュ整合性は未対応。

回帰: `python3 tests/run_tests_access_alignment.py`。
入力 `tests/c/t260_access_alignment.c` と追加C/JSONは独自作成。外部コード・仕様・依存追加なし。
