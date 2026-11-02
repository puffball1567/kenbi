# 確保契約（allocates）

2026-09-27。`source-allocation-contract.c.v1` を実装。
外部 API 契約の `allocates` は「呼び出しごとに新しい記憶領域を返す」という宣言で、
`malloc` のような確保関数を記述する。返された領域は、容量・整列・解放・借用の各検査に
宣言済みの自動変数と同じように接続される。

```json
{"symbol": "c:@F@malloc", "effects": ["heap_allocate"], "assumption": "libc",
 "preservesProtocols": true, "accesses": [],
 "allocates": {"sizeArgument": 1, "alignment": 16, "nullable": true, "releasedBy": ["c:@F@free"]}}
```

- `sizeArgument`（必須）: バイト数を渡す引数の番号（1始まり）。
- `countArgument`: 要素数を渡す引数の番号。指定時は領域の大きさを size × count とする（`calloc` 型）。
  `sizeArgument` と同じ番号は設定エラー。
- `alignment`（必須）: null でない結果が必ず満たす整列。1〜536870912 の2の冪。
- `nullable`: true なら null を返す経路も探索する。省略時 false（null を返さないという宣言）。
- `region`: 結果が置かれる領域（[メモリ領域](configured_memory_regions.md)）。
- `capacity`: 同時に生存できる結果の数の上限（固定プール等）。1〜1000000。下記「資源上限」参照。
- `releasedBy`（必須）: 結果を解放・再配置してよい関数のシンボル。組み込みの `free` / `realloc`、
  または `release` / `relocate` アクセスを宣言した契約でなければ設定エラー。

未知キー・欠落・不正な型は設定エラー（終了コード2）。`returnPointer` との同時指定、
プロトコル操作の関数への指定も設定エラー。関数の戻り値がポインタでない、または
指定引数が呼び出しに無い場合は `ALLOCATION_ARGUMENT_MISMATCH`（未検証）。
解放は従来どおり `accesses` の `release`（`realloc` 型は `relocate`）で宣言する。
`free` / `realloc` は組み込みで release / relocate として扱う。

## 検査内容

- 大きさ: 引数がコンパイル時定数なら、その値を領域の大きさとして範囲検査に使う。
  定数でない場合は大きさ不明で、アクセスや容量要求は未検証。乗算が溢れる場合も不明とする。
- 整列: 宣言値を先頭の保証として使う。より強い整列の要求は未検証（整列を推測で強めない）。
- null: `nullable` なら null 経路で null を確認しないアクセスが `NULL_POINTER_ACCESS`。
- 解放: 解放後のアクセス・ポインタ値の使用・二重解放は `EXPIRED_BORROW_ORIGIN`。
  別名（`q = p + 4` 等）も同じ起点として失効する。
- 解放元: `releasedBy` に無い関数での解放・再配置は `RELEASE_ALLOCATOR_MISMATCH`（違反）。
  `free` / `realloc` に確保契約由来でない領域（自動変数・引数の記憶域）を渡すと
  `RELEASE_NOT_ALLOCATED`（違反）。確保物の途中を指すポインタの解放は
  `RELEASE_NOT_ALLOCATION_START`（違反）。先頭かどうか確立できなければ
  `UNKNOWN_RELEASE_POSITION`（未検証）。大きさが実行時値でも、ポインタ演算を経ていない
  確保結果は先頭として扱う。既知の null への `free` / `realloc` は解放を行わない。
- 借用: 確保した領域を非同期借用に渡せる。借用中の解放は `BORROW_ACCESS_CONFLICT`、
  容量・整列・マークの要求も通常の借用と同様に検査する。

## 同じ確保位置の再実行

領域の識別子は「呼び出しフレームと確保呼び出しの位置」から作る。ループや同じ関数の
再呼び出しで同じ位置に再び到達したとき、以前の領域を名指すもの（この関数・呼び出し元の
ポインタ束縛、借用、状態、マーク、未処理のポインタ結果）が残っていれば別の識別子を使う。
これにより、解放済みの古いポインタが新しい領域として扱われることはない
（例: ループ内で前回の確保物を指すポインタ、ヘルパー経由で二度確保したときの古い戻り値）。
識別子は数を増やし続けず再利用するため、ループの探索は収束する。

メモリ内に格納したポインタ（配列要素・構造体メンバー経由）は起点を持たない値として扱い、
それを通したアクセスは従来どおり未検証になる。

## 資源上限（2026-10-02）

`source-allocation-limits.c.v1`。確保のたびに、その経路で生存している確保物を数えて照合する。
解放済み（失効）でない確保物はすべて数える。参照が失われたもの（リーク）も含む。

- 確保契約の `capacity`: 同じ確保関数の生存数が上限を超えると `ALLOCATION_CAPACITY`（違反）。
- プロファイルの `maxLiveHeapBytes`: 全確保物の生存バイト数の合計が上限を超えると
  `HEAP_BUDGET_EXCEEDED`（違反）。`extends` で複数指定された場合は小さい方を適用する。
- 次の場合は数えられないので未検証（`UNKNOWN_HEAP_USAGE` / `UNKNOWN_ALLOCATION_CAPACITY`）:
  大きさが定数でない確保、上限のあるプロファイルで `heap_allocate` 効果を持つが `allocates`
  契約の無い呼び出し、同じ確保位置の再実行で、まだ生存している可能性のある以前の確保物の
  識別子を再利用した場合（ループ内のリーク等）。

各 obligation の `resourceLimits` に、上限・その時点の生存数／生存バイト数・判定を記録する。
null を返す経路は確保しなかったものとして数えない。
スタック使用量、ループ回数の上限、実行時間は対象外。

## 前提と対象外

確保関数の振る舞い（大きさ・整列・null の有無）は契約の `assumption` として conditional の
前提に残り、注釈だけで verified へ昇格しない。

解放漏れ（リーク）は報告しない。確保直後の内容は未初期化だが、初期化前の読み取りは
この検査の対象外。`free` / `realloc` 以外の契約上の `release` は汎用の「以後使えない」宣言のため、
確保契約由来でない領域に適用しても解放元の誤りとはしない。
可視本体を持つ確保関数の契約適合確認は未対応。

## 回帰

`tests/c/t298_allocation_contract.c` と `tests/run_tests_allocation.py`（49件）、
資源上限は `tests/c/t301_allocation_limits.c` と `tests/run_tests_allocation_limits.py`（23件）。
DMA 受け入れ例（[バッファマーク](configured_buffer_marks.md)参照）の `free_during_tx` も
この契約で検査する。独自作成の入力のみ。外部コード・仕様・依存の追加はない。
