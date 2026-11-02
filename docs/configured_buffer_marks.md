# バッファマーク（キャッシュ保守などの前後条件）

2026-09-25。`source-buffer-marks.c.v1` を実装。
バッファのバイト範囲に付く名前付きの事実（マーク）を宣言し、外部操作で付け外しして、
借用の開始条件や CPU アクセスの禁止として検査する。キャッシュのクリーン/インバリデートが
代表例だが、語彙は汎用で、特定デバイスやアーキテクチャの名前は持たない。

## 定義

契約（`kind: "contracts"`）またはプロトコル（`kind: "protocols"`）文書の `marks` で定義する。

```json
"marks": [
  {"id": "cache_clean", "clearedBy": ["write"]},
  {"id": "cache_stale", "forbids": ["read"]}
]
```

- `clearedBy`: その種類の CPU アクセスが触れたバイトではマークが消える。
- `forbids`: その種類の CPU アクセスはマークが付いたバイトに対して禁止。
- 値は `read` / `write` のみ。どちらも持たない定義、重複、未知キーは設定エラー（終了コード2）。
- 同じ id を複数文書で定義する場合、内容が同一なら一つの定義として受理し、異なれば設定エラー。
- 参照されたが定義されていないマークは設定エラー（`unknown mark 'X'`）。

## 操作

関数契約の `marks` でマークを付け外しする。

```json
{"symbol": "c:@F@cache_clean", "effects": [], "assumption": "dma.cache.behaviour",
 "preservesProtocols": true, "accesses": [{"argument": 1, "mode": "read"}],
 "marks": [{"argument": 1, "lengthArgument": 2, "set": ["cache_clean"]}]}
```

- `argument`: 対象バッファの引数番号（1始まり）。
- `lengthArgument`: 対象バイト数の引数番号。省略時はポインタ位置からストレージ末尾まで。
  `argument` と同じ番号は設定エラー。
- `set` / `clear`: 付ける・外すマーク。少なくとも一方が必要で、同じマークを両方に書けない。

プロトコルの `borrow` には次を指定できる。

- `lengthArgument`: 借用するバイト数の引数番号。省略時はストレージ末尾まで。
- `requireMarks`: 借用開始時に、借用するバイト全体が持っていなければならないマーク。
- `marksOnRelease`: 借用が終わった時点で、借用していたバイトに付くマーク
  （デバイスが書いた後のキャッシュ不整合など）。借用を開始する操作にのみ書ける。

## 判定

マークはストレージの起点ごとに、確実に付いているバイト範囲（definite）と
付いている可能性があるバイト範囲（possible ⊇ definite）を経路ごとに保持する。

- 要求（`requireMarks`）: definite が借用範囲を覆えば検証済み。possible すら覆わないバイトが
  確実にあれば `BORROW_MARK_REQUIRED`（違反）。それ以外は `UNKNOWN_BORROW_MARK`（未検証）。
- 禁止（`forbids`）: 定数位置・幅の CPU アクセスが definite に触れれば `MARK_FORBIDS_ACCESS`
  （違反）。possible にのみ触れる、または位置が不明なら `UNKNOWN_MARK_ACCESS`（未検証）。
- バイト数が定数でない操作は、付ける側では「どこかに付いた可能性」、外す側では
  「どこでも確実ではなくなった」として扱う。どちらも検証済みにも違反にもならない。
- 対象ストレージを特定できないマーク操作は `UNKNOWN_MARK_TARGET`（未検証）。
  契約の引数番号が呼び出しに存在しなければ `MARK_ARGUMENT_MISMATCH`（未検証）。
- 寿命の終了・解放・再配置でその起点のマークはすべて消える。同じ場所の新しい寿命は無印から始まる。
- 分岐の合流は経路を分けたまま扱うため、片方の経路でだけ付いたマークは要求を満たさない。

外部 API の契約上の `read` / `write` アクセスは、アクセスのバイト数が契約に無いため
位置不明の CPU アクセスとして扱う（禁止マークがあれば未検証、消去マークは確実でなくなる）。

各診断の `markRequirement` にマーク名・定義ファイル・借用範囲（`byteRange`）・
確実にマークが付いていた範囲（`markedBytes`）・判定を記録する。
レポートの `markDefinitions` に使用したマーク定義とその出典を列挙する。

マークはデバイス・キャッシュの振る舞いを証明しない。操作の意味は契約の `assumption` として
conditional の前提に残る。マークが実際のキャッシュ状態と一致することは契約側の責任である。

## 対象外

- キャッシュライン境界への丸め（領域の区別は[メモリ領域](configured_memory_regions.md)を参照）。
- 契約上のアクセスへのバイト数指定。

## DMA 受け入れ例

`demo/dma/` に同一ドライバ `dma_driver.c` と、要求だけが異なるデバイス仕様がある
（DMA 可能領域を要求するデバイス C は[メモリ領域](configured_memory_regions.md)を参照）。

- `device-a.*`: 4バイト整列、非コヒーレント（送信前 `cache_clean` 必須、受信後 `cache_stale`）。
- `device-b.*`: 32バイト整列、コヒーレント（マーク要求なし）。

```bash
./kenbi --format=json --safety=demo/dma/device-a.project.json
./kenbi --format=json --safety=demo/dma/device-b.project.json
```

初期化前の開始・転送中の再開始・転送中の CPU 書き込み/読み出し・完了前の寿命切れ・
容量不足・キャッシュ保守の欠落や部分的な保守・受信後のインバリデート漏れ・
失敗時の回復漏れ・取消後の停止待ち漏れ・割り込み文脈からの割り当て・契約の無い API を、
デバイスごとに違反または未検証として報告する。オフセット4のバッファは A では受理、
B では整列違反になる。キャッシュ関連の行は A でのみ違反になる。

ループでの再開始は、符号付きカウンタの for 文を通して二回目の開始を違反として報告する。
`malloc` は[確保契約](configured_allocation.md)（16バイト整列）で宣言しており、
転送中の `free` は A で違反になる。B は 32 バイト整列を要求し、確保契約の整列では
満たせるか分からないため、同じ行が整列の未検証で止まる。
期待結果は `tests/run_tests_dma_acceptance.py` で固定し、違反・未検証の行が
conditional や verified として報告されないことも同テストで確認する。

独自作成のテスト `tests/c/t296_buffer_marks.c` と `tests/run_tests_marks.py` で検証する。
新規依存・外部コードやデバイス仕様の取り込みはない。
