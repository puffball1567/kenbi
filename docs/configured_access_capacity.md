# 外部APIアクセスの容量要求

`contracts.functions[].accesses[]` の `read` / `write` に `minBytes` を指定できる。
非同期借用の `borrow.minBytes` と同じ固定長ストレージ・定数オフセット追跡を使う。

```json
{"symbol":"c:@F@consume","effects":[],"assumption":"api.behavior",
 "accesses":[{"argument":1,"mode":"read","minBytes":8}]}
```

`minBytes` は呼び出し時に要求する最小の残り容量で、1〜1000000000 の整数。
`release` / `relocate` への指定、同一引数・モードの重複は入力エラー。
実際のアクセス長の上限を表すフィールドではない。APIが宣言した契約に従うことは
外部前提であり、容量要求を満たしただけでAPI内部の全アクセス安全性を証明しない。

設定中にこの要求があれば、各検証対象で順序付きメモリ解析を実行する。
状態機械の選択は不要。既存の禁止効果・文脈・深度等のprofileと併用する。
完全な外部 `accesses` 契約を要求するため、途中の不明な呼び出しで解放・再配置を
見落として成功にすることはない。設定内の未使用契約にも要求がある場合、同じ
順序付き解析を保守的に実行する。可視関数の本体は追跡するが、その関数自身にも
メモリ契約がある場合の一般的な実装適合証明は `MEMORY_CONTRACT_BODY_UNVERIFIED`。

- `MEMORY_CAPACITY_REQUIREMENT`: 既知の残り容量が要求未満。one-pastは残り0。
- `MEMORY_POINTER_RANGE`: 追跡したポインタ演算がストレージ範囲を逸脱。
- `UNKNOWN_MEMORY_CAPACITY`: パラメータ起源・動的オフセット等で容量不明。
- `MEMORY_ARGUMENT_MISMATCH`: 契約の引数が存在しない。

別名・定数オフセット・可視ヘルパー・別翻訳単位・分岐・ループを追跡し、
既存の読み取り専用制約、解放済み起源、借用競合も検査する。
ブロックは囲む関数全体を解析して前後の起源と外部前提を維持し、範囲を
`protocolScope` に記録する。未対応構文や解析予算超過は未検証になる。

結果のcapabilityは `source-access-capacity.c.v1`。
各obligationの `accessCapacity` に要求値・観測サイズ・バイトオフセット・残り容量・
個別判定・契約ファイル・呼び出し連鎖を記録する。不明な観測値はnull。
全体のconditional判定と外部前提は引き続き保持する。

可変アクセス長と引数の関係、ヒープ容量、物理領域、MMIOアクセス幅は未対応。
単位はClangのC sizeof単位であり、物理バスのアクセス単位ではない。

回帰: `python3 tests/run_tests_access_capacity.py`。
入力 `tests/c/t259_access_capacity.c` とテスト内の追加入力は独自作成。
外部仕様・コード・依存は追加していない。
