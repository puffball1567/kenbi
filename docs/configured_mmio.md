# MMIO レジスタアクセス

2026-10-01。`source-mmio-registers.c.v1` を実装。
整数定数のアドレスを通した volatile アクセスを、宣言されたレジスタマップと照合する。
アクセス権・幅・書き込みでクリアされるビット・読み出しでクリアされるビット・予約ビットを検査する。
マップに無いアドレスは推測で許さず、未検証にする。

## 対象となるアクセス

アドレスが整数定数式で、アクセスする左辺値が volatile 修飾されているもの。

```c
#define CTRL (*(volatile u32 *)(DEV_BASE + 0x00))
CTRL = 1u;  CTRL |= 2u;  v = CTRL;
((dev_regs *)DEV_BASE)->status;      /* 構造体のメンバーオフセットで位置を求める */
*(volatile u32 *)0x40001008u = 7u;
```

- 読み出し、代入、複合代入（read-modify-write）、`++` / `--`（read-modify-write）。
- 書き込み値が整数定数式ならその値で予約ビットを判定する。それ以外は値不明。
- ビットフィールドのメンバー、アドレスをポインタ変数に保持してからのアクセスは未対応（未検証）。

## レジスタマップ

プロトコル文書（`kind: "protocols"`）の `mmio` で宣言する。レジスタマップだけを持つ文書では
`machines` を省略できる。アドレスとマスクは整数、または `"0x4000_1000"` 形式の16進文字列。

```json
"mmio": {
  "assumption": "dev.registers",
  "blocks": [{"id": "dev", "base": "0x40001000", "size": "0x100"}],
  "registers": [
    {"id": "CTRL", "address": "0x40001000", "width": 4, "access": "read-write",
     "reserved": {"mask": "0xFFFF0000", "write": "zero"}},
    {"id": "STATUS", "address": "0x40001004", "width": 4, "access": "read-only"},
    {"id": "FLAGS", "address": "0x4000100C", "width": 4, "access": "read-write", "writeOneToClear": "0xFF"},
    {"id": "EVENTS", "address": "0x40001010", "width": 4, "access": "read-write", "readToClear": "0xF"}
  ]
}
```

- `assumption`（必須）: 実機がこのマップどおりに振る舞うという外部前提。照合に成功した
  アクセスはこの前提付きの conditional になり、`acceptedAssumptions` に無ければ受理しない。
- `width`: 1 / 2 / 4 / 8 バイト。アドレスは幅に整列していること。
- `access`: `read-write` / `read-only` / `write-only`。
- `reserved.write`: `zero`（0 を書く）または `preserve`（読んだ値を書き戻す）。
- `reserved.readsAs`: `zero` のみ。予約ビットが常に 0 として読めるという宣言（任意）。
- `writeOneToClear` / `readToClear`: 該当ビットのマスク。読み出し専用レジスタに W1C、
  書き込み専用レジスタに読み出しクリアは設定エラー。
- `blocks`: レジスタだけを含むアドレス範囲。範囲内でレジスタの無いアドレスへのアクセスは違反。

重複・重なり・幅を超えるマスク・未知キーは設定エラー（終了コード2）。

## 判定

| コード | 状態 | 内容 |
|---|---|---|
| `MMIO_READ_ONLY_WRITE` | 違反 | 読み出し専用レジスタへの書き込み・read-modify-write |
| `MMIO_WRITE_ONLY_READ` | 違反 | 書き込み専用レジスタの読み出し・read-modify-write |
| `MMIO_ACCESS_WIDTH` | 違反 | レジスタの幅・位置と一致しないアクセス |
| `MMIO_WRITE_ONE_TO_CLEAR_UPDATE` | 違反 | W1C ビットを持つレジスタの read-modify-write（立っているビットを書き戻して消す） |
| `MMIO_READ_TO_CLEAR_UPDATE` | 違反 | 読み出しクリアのビットを持つレジスタの read-modify-write（読み出しで事象を失う） |
| `MMIO_RESERVED_BITS` | 違反 | 予約ビットの規則を確実に破る書き込み |
| `UNKNOWN_MMIO_RESERVED_BITS` | 未検証 | 予約ビットに残る値が確立できない |
| `MMIO_UNDECLARED_REGISTER` | 違反 | ブロック内でレジスタが宣言されていないアドレス |
| `UNKNOWN_MMIO_ADDRESS` | 未検証 | どのマップにも無いアドレス（マップが無い場合も） |

予約ビットの判定（M = 予約マスク、C = 定数値）:

- 代入 `= C`: `zero` は `C & M == 0` なら適合、そうでなければ違反。`preserve` は常に違反
  （読んでいないビットは書き戻せない）。値不明は未検証。
- `|= C`: `C & M != 0` は違反（予約ビットを立てる）。`preserve` で `C & M == 0` は適合。
  `zero` で `C & M == 0` は、予約ビットが読み出し値のまま書かれるため未検証。
- `&= C`: `preserve` で `C & M == M`、`zero` で `C & M == 0` なら適合。その他は未検証。
- `^= C`: `preserve` で `C & M == 0` は適合、`!= 0` は違反。`zero` は未検証。
- `zero` かつ `readsAs: "zero"` の場合、read-modify-write は予約ビットへ OP(0, C) を書くので、
  `|= C` と `^= C` は `C & M == 0` なら適合・それ以外は違反、`&= C` は常に適合。
- `++` / `--`、その他の演算子は予約ビットがあれば未検証。

各 obligation の `mmioAccesses` に、アドレス・幅・アクセス種別・演算・定数値・該当レジスタ・
ブロック・定義の出典・判定を記録する。レポートの `mmio` に使用したマップを列挙する。

検査は、プロトコルまたは `memoryAccess` を有効にしたプロファイルの順序付き解析の中で行う。

## メモリ書き込みとの順序（2026-10-08）

デバイスにメモリ上のデータ（DMA ディスクリプタ等）を読ませる前に、CPU の書き込みを確定させる
バリアが要る場合がある。これを宣言で検査する。

- 外部関数の契約に `"barrier": ["full"]` と書くと、その呼び出しが種類 `full` のバリアになる。
  種類名は汎用の文字列で、kenbi は特定の命令を知らない。
- レジスタに `"requiresBarrier": "full"` と書くと、そのレジスタへの書き込みの前に、直近の通常メモリ
  への書き込み（ローカル・メモリ書き込み・外部 API 契約の write）の後でその種類のバリアを通っていることを
  経路ごとに要求する。MMIO レジスタへの書き込みは通常メモリへの書き込みに数えない。
- 経路上に書き込みがありバリアが無い: `MMIO_BARRIER_REQUIRED`（違反）。
- 検査対象の関数の入口より前（呼び出し元）の書き込みは分からないため、入口からバリアを通らずに
  書いた場合は `UNKNOWN_MMIO_BARRIER`（未検証）。
- 未宣言の種類を要求する、読み出し専用レジスタに要求を付けるのは設定エラー。

## 対象外

バリアの種類間の包含関係（強いバリアが弱いバリアを兼ねる等）、キャッシュとの関係、レジスタ値の状態機械（有効化前の書き込み禁止等）、
ビットフィールド、ポインタ変数経由のアクセス、配列メンバー・入れ子構造体のメンバー、
DMA 記述子のようなメモリ上の構造。

## 回帰

`tests/c/t300_mmio_registers.c` と `tests/run_tests_mmio.py`（71件）。fixture は解析用の入力で、実行はしない。
独自作成の入力と架空のレジスタマップのみ。実在デバイスの仕様の転載はない。
