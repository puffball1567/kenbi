# 設定による操作制約の検証

`kenbi --safety=project.json` は、指定した C 関数・ブロックとその呼び出し先に対し、
設定された操作制約を必須検証する。この操作制約の能力 ID は `source-effects.c.v1`。
[状態遷移検証](configured_protocols.md)をプロファイルに追加することもできる。
所有ポインタを引数に渡さない関数呼び出し、条件式や return 式の呼び出しも追跡する。

```sh
kenbi --format=json --safety=demo/safety/project.json
```

付属例は、純粋な関数を `verified`、ヘルパー経由で待機APIを呼ぶ関数を `violation` と報告し、
終了コード 1 を返す。[ソース](../demo/safety/driver.c)、[設定](../demo/safety/project.json)、
[外付け契約](../demo/safety/board.contracts.json)を参照。

## 検証する性質

| 効果 | 意味 |
| --- | --- |
| `heap_allocate` | ヒープ割り当てを行い得る |
| `recurse` | ソースの呼び出しグラフに循環がある、または外部契約が再帰を宣言する |
| `block` | ブロッキングを行い得る |
| `wait` | 待機を行い得る |

設定した禁止集合と、呼び出し閉包の可能な効果集合の交わりが空であることを検査する。
分岐・ループ中の呼び出しも集合に含める。再帰は呼び出し経路上の循環を検出し、
[recurse 効果](configured_recursion.md)として報告・禁止できる。
これは保守的な効果解析で、経路の実行可能性やループの終了性は証明しない。
`FORBIDDEN_EFFECT` は静的な可能効果の上限が要求に反することを示し、実際にその経路を実行したという意味ではない。

標準 C の `malloc`, `calloc`, `realloc`, `aligned_alloc`, `posix_memalign`, `strdup`, `strndup` は
外部関数である場合、版付きモデルの割り当て操作として認識する。
同じ関数の実装を解析している場合はその本体をたどる。
独自APIは本体または外付けの効果契約が必要。解放関数も「割り当てない」と暗黙には決め付けない。
既知のアロケータも、割り当てるという事実だけでは「ブロックしない・待機しない」とは証明できない。
その効果は外付け契約がなければ未検証として残す。

この能力の `verified` は**指定されたソース上の操作制約についての結果**である。
所有権・寿命・排他借用・MMIO・DMA・スタック・WCETや、コンパイラが機械語に挿入する処理を
含む低レベル安全性全体の保証は、まだこのコマンドに統合されていない。
既存の所有権・空間・ロック等の検査は従来の CLI で実行する。

## Project ファイル

```json
{
  "schemaVersion": 1,
  "kind": "project",
  "id": "my_driver",
  "sources": ["driver.c", "helper.c"],
  "clangArgs": ["-I", "include", "-DDEVICE_REV=2"],
  "contracts": ["board.contracts.json"],
  "profiles": {
    "irq": {"forbid": ["heap_allocate", "block", "wait"]},
    "no_heap": {"forbid": ["heap_allocate"]}
  },
  "checks": [
    {"file": "driver.c", "function": "irq_entry", "profile": "irq"}
  ],
  "acceptedAssumptions": ["board.wait.contract"]
}
```

`schemaVersion`, `kind`, `id` は各仕様ファイルに必須。
合成後の `sources` は空にできず、少なくとも一つの `checks` または `@verify` が必要。
`profiles` の各 profile は空でない `forbid` または `protocols` を持つ。
その他の省略可能フィールドは空として扱う。

ファイル参照は宣言元 JSON のディレクトリ基準。
`clangArgs` の相対パスもそのフィールドを宣言した JSON のディレクトリ基準である。
解析に使った有効引数を結果に出力する。安全性に関わるコンパイル条件を黙って落とさないため、
このモードは compile database を暗黙に探索しない。必要な条件を `clangArgs` に指定する。
compiler response file は未対応として拒否する。Clang の警告・エラーは入力エラーとして拒否する。

`--safety` と従来のファイル指定、`--project`、`--compile-commands`、`--emit-contracts`、
`--dump-ir`、追加 Clang 引数の同時指定はエラー。同じオプションの重複や空パスも拒否する。

`checks` は定義ファイルと関数名が一致する定義を一意に選ぶ。`symbol` を追加指定すると
Clang USR でも一致を要求する。ゼロ件・複数件の一致はエラー。
内部リンケージのシンボルは定義ファイルを含む ID とし、別ファイルの同名 `static` 関数を混同しない。
一致した ID は結果の `symbol` と診断の `callChain` に出力する。

## 関数・ブロックの必須検証

```c
// @verify(irq)
int irq_entry(void) {
  return helper();
}

void routine(void) {
  initialize();
  // @verify(no_heap)
  {
    process();
  }
}
```

`@verify(profile)` は直後の関数定義または `{ ... }` ブロックに適用する。
空白とコメントを挟める。任意の文へ自動的に範囲を広げず、結び付けられない注釈はエラー。
未知 profile、不正構文、設定なしの通常解析もエラーにする。注釈が黙って無視されて成功しない。

ブロック内の呼び出し先は関数全体をたどる。ブロック外の直接操作はそのブロックの禁止集合には含めない。
この軸に持続する状態は効果集合であり、所有状態や非同期借用のブロック入出力契約は今後の実装対象。
`@unsafe` はこの検査を抑制しない。
外側で宣言した cleanup 属性付きローカルも、ブロック内の return で終了処理を呼び得る。
このため、囲む関数にある未対応構文の不確実性はブロックにも保守的に引き継ぐ。

## 外付け効果契約

```json
{
  "schemaVersion": 1,
  "kind": "contracts",
  "id": "example.board",
  "version": "1",
  "functions": [
    {
      "symbol": "c:@F@board_wait",
      "effects": ["block", "wait"],
      "assumption": "board.wait.contract"
    }
  ]
}
```

`functions` の各要素には `symbol`, `effects`, `assumption` を必須とする。
`effects: []` はrecurse を含む対応効果を一つも生じないという契約で、外部実装なら明示された前提である。
`preservesProtocols` は状態遷移検証用の省略可能な真偽値（[意味と制約](configured_protocols.md)）。
`accesses` は[持続借用検証](configured_async_borrows.md)用の外部メモリアクセス契約。
操作制約だけを選択した結果は、この追加契約の適合性まで検証済みであるとは意味しない。
`version` は宣言版を記録するもので、ライブラリ実体との版一致の証明ではない。

外部契約は USR で呼び出しに結び付ける。名前だけで overload 全体に適用しない。
どの定義・呼び出しにも一致しない契約、同じシンボルへの複数契約は入力エラー。
既知の割り当て操作を `effects: []` で純粋な操作へ変更できない。
実装を解析できる場合は宣言で置き換えず、本体の効果が契約の集合に収まることを確認する。
未解決の呼び出し等が本体に残れば契約適合性も未検証となる。

宣言は検証結果ではない。契約に `verified` 等の未知フィールドを追加すると入力エラーになる。
`acceptedAssumptions` は許容する前提の明示的なリストで、許容しても `conditional` は `verified` にならない。

## 継承・厳密な入力検査

Project の `extends: ["base.json"]` で共通設定を再利用できる。

- 同じ profile の禁止集合は和集合で合成し、継承先から禁止を取り除けない。
- sources、checks、契約参照、許容前提は重複を除いて合成する。
- 異なる有効 `clangArgs` は競合として拒否する。仕様 ID の衝突、契約シンボルの衝突も拒否する。
- 循環参照、存在しないファイル、未知キー・効果・profile・前提、型不一致を拒否する。
- JSON の重複キーはオブジェクト化の前に拒否し、エスケープ表記の同じキーも検出する。
  コメント、末尾コンマ、余分な文書、不正 UTF-8 は受理しない。

schema version 1 の kind は `project` と `contracts`。
`target` / `device` や状態機械等を、現時点の parser が読み飛ばすことはない。未対応形式はエラーになる。

## 結果・終了コード・追跡情報

| status | 意味 |
| --- | --- |
| `verified` | 指定された効果の義務が成立し、外部契約への依存なし |
| `conditional` | 明示された外部契約の下で義務が成立 |
| `unverified` | 未解決呼び出し、契約欠落、解析未対応など |
| `violation` | 禁止効果または契約との不整合を検出 |

0 = accepted、1 = 違反・未検証・未許容前提、2 = 入力・設定・パースのエラー。
conditional でも全前提が project に明示的に許容されていれば 0 になる。
全体と個々の義務の status を別々に記録する。違反と未検証が同時にあっても各診断を残す。

JSON には対象ソース・関数/ブロック範囲・profile・能力 ID・呼び出し列・前提・契約の出典と宣言版、
Clang 版・Kenbi 版と実行バイナリの fingerprint・有効引数・作業ディレクトリを出力する。
設定、契約、ソースと Clang が読んだヘッダの内容 fingerprint は `inputs` に保持する。
この版は SHA-1 を変更追跡に使用し、署名や外部証明の検証には使用しない。
毎回すべての設定済み翻訳単位を解析し、過去の結果やキャッシュを証明として再利用しない。

## 現在の解析境界

C++ の暗黙の構築・破棄・dispatch、関数ポインタの候補解決、inline assembly、cleanup 等の
局所属性、sizeof / alignof の可変長配列評価、並列 pragma の runtime 効果は未対応として成功を拒否する。
純粋性を推測してこれらの呼び出しを消さない。C++ の既存所有権検査への対応とは別の能力である。

次の段階は、所有権等との統合、汎用状態機械と持続借用、target / device の領域・MMIO・DMA 制約。
資源量・実時間の証拠も別途必要であり、この source-phase 結果から時間保証を導かない。

## 検証

```sh
nimble testsafety
```

実 C/C++ を CLI に渡して、禁止効果の推移、複数翻訳単位、内部シンボル、必須ブロック、
契約適合性、前提と四分類、入力の不正、継承、依存ヘッダ変更を検査する。
既存 C/C++ テストの `t236_configured_effects.c` でも従来の所有権解析を維持することを確認する。
