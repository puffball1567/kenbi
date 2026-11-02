# 設定によるリソース状態遷移の検証

`--safety` のプロファイルに `protocols` を指定すると、外付け状態機械を実際の C の
操作順序に適用する。能力 ID は `source-protocols.c.v1`。
[操作制約](configured_effects.md)と同時に実行し、いずれかの違反・未検証でビルドを拒否する。
この能力は状態遷移とローカル資源の終了状態を対象とする。
[持続借用](configured_async_borrows.md)も追加指定できるが、DMA やメモリ安全性全体の証明ではない。

## 外付け仕様

プロジェクトに `"protocols": ["device.protocols.json"]` を追加し、例えば
`"profiles": {"driver": {"protocols": ["transfer"]}}` と指定する。
`forbid` と併記でき、少なくとも一つの操作制約か状態機械が必要。
`extends` では両方の要求集合を和集合で継承し、親の要求を削除できない。

```json
{
  "schemaVersion": 1,
  "kind": "protocols",
  "id": "example.device",
  "version": "1",
  "machines": [{
    "id": "transfer",
    "states": ["new", "ready", "busy"],
    "initial": "new",
    "terminal": ["new", "ready"],
    "operations": [
      {"symbol": "c:@F@device_init", "argument": 1, "from": ["new"], "to": "ready"},
      {"symbol": "c:@F@device_start", "argument": 1, "from": ["ready"], "to": "busy"},
      {"symbol": "c:@F@device_finish", "argument": 1, "from": ["busy"], "to": "ready"}
    ]
  }]
}
```

`argument` は状態を持つ資源へのポインタを渡す引数番号（1始まり）。
シンボルには効果契約と同じ Clang USR を使う。
同一操作への重複・競合する指定、未知状態、不正な引数番号、未知キー・仕様版は入力エラー。
操作には別途 `contracts` ファイルの `symbol`, `effects`, `assumption` が必須。
操作が呼ばれた場合、その前提は結果に残り、`acceptedAssumptions` に含めても `verified` に昇格しない。

モデルは、追跡可能な自動変数のアドレスを資源の識別子とし、最初の操作の前を `initial` とする。
これは実機の初期状態を測定・証明したものではなく、外部モデルの前提である。
`from` が操作直前の状態に適合することを検査し、適合する場合に `to` へ遷移する。
`terminal` はそのローカル資源のスコープ終了・return 時に許容する状態。
初期化、開始、完了、キャンセル等の名前は固定されておらず、仕様側で定義する。
例えばキャンセル受付を `busy → cancelling`、停止確認を `cancelling → ready` と定義すれば、
停止確認前の再開始や関数復帰を検出できる。

各外部操作の契約は、正常復帰時に指定した遷移が成立し、他の追跡対象資源を変更・破棄せず、
非局所的な制御移動を起こさないというモデルを含む。
それに適合しない API はこのモデルでは扱えない。`int` 戻り値を持つ操作は、
[結果別の遷移](configured_protocol_results.md)で zero/nonzero 両方の契約を指定できる。
それ以外の非 void 操作や結果契約の欠落は `UNSUPPORTED_PROTOCOL_RESULT` となる。
`void` であっても実装に失敗経路がある場合、無条件の遷移を成立するものとして契約に記載してはならない。

## C の追跡範囲

- ブロックの順序、`if` の両分岐、`while` の反復、`break` / `continue` / `return`。
- 同じ資源を参照する単純なポインタ初期化、引数を経由した呼び出し、別翻訳単位の可視ヘルパー。
- ローカル資源ごとの独立状態、入れ子のスコープ、同名変数の区別。

`while` は到達した環境・状態の組が再出現するまで探索する。
条件が定数なら成立する側だけを扱い、その他は成立・不成立の両方を可能とする。
条件式間の相関や数値範囲は証明しないので、実行不能な経路を含む保守的な違反判定があり得る。
処理量上限・ループ終了性・実時間の証明ではない。
探索量・経路数・呼び出し深度の内部上限に達した場合は `PROTOCOL_ANALYSIS_LIMIT` 等で未検証となる。
上限はプロジェクトの資源制約が証明された事実ではない。

操作の本体が解析対象に存在する場合、宣言した状態遷移を無条件には信用しない。
現段階では本体と抽象状態機械の適合検査が未実装のため、
`PROTOCOL_IMPLEMENTATION_UNVERIFIED` とする。通常のヘルパー本体は展開して追跡する。

状態機械の操作でない外部呼び出しには、効果契約だけでは状態保存を認めない。
外部契約に `"preservesProtocols": true` を指定した場合に限り、追跡対象の状態・寿命を変更せず、
非局所的な制御移動も起こさないという明示的な外部前提として扱う。
ここでの追跡対象は状態機械のリソースであり、別のバッファが不変であるとは主張しない。
この指定は借用、任意のメモリ書き込み、スレッド安全性の証明を与えるものではない。
借用を含むモデルでは、さらに完全な `accesses` 契約が必要になる。
状態遷移操作との併用は矛盾として入力エラーになる。

## 未検証になるもの

現時点では、状態を持つ引数・グローバル・static 資源の入口契約、
再帰、`for` / `do` / `switch` / `goto`、ポインタの再代入、フィールドや配列要素の状態、
状態資源への直接書き込み、非単純な引数・条件式、関数引数の動的配列境界などは未検証。
配列・ポインタ・数値型変数の単純な読み書きは、[借用検査](configured_async_borrows.md)の範囲で扱う。
未モデル化構文はそこで経路追跡を止め、成功判定に使わない。
効果解析は独立して呼び出し全体の診断を継続する。

`@verify` の関数指定で状態機械を要求できる。
ブロック指定は[囲む関数全体の状態追跡](configured_protocol_blocks.md)を利用する。
独立したブロック入口・出口契約は未実装。
ブロックが空でも、状態を勝手に初期化して検証済みにしない。
操作制約のみのブロック検証は従来どおり利用できる。

借用の入口・出口契約やヒープ由来の統合、MMIO、領域・アラインメント、IRQ 文脈、
所有権解析との統合、一般の結果条件・値域、資源上限、WCET は引き続き別の未完了項目。

## 結果と再現性

`PROTOCOL_PRECONDITION` は操作直前の状態違反、`PROTOCOL_EXIT_STATE` は終了時の非終端状態。
診断にはファイル、行、呼び出し経路が付く。終了状態の診断行は資源を含むスコープの開始行。
既存の四分類・終了コードを共有する。
`capabilities` に能力 ID、各 obligation に選択した `protocols`、
`protocolSpecifications` に仕様 ID・パッケージ・宣言版・出典・初期状態・終端状態を記録する。
仕様の内容ハッシュは既存の `inputs` に含み、毎回再解析する。
宣言版は外部ライブラリ実体との一致を証明するものではない。

回帰テスト: `python3 tests/run_tests_protocols.py`（実行前に `kenbi` をビルド）。
フィクスチャとモデルはこのリポジトリ用の架空の例であり、ベンダーのコード・仕様を転用していない。
新しいパッケージ依存も追加していない。

## 同一コードへの異なる仕様の適用

以下は同じ [C ソース](../demo/safety/protocol_driver.c) と外付け API 契約を使用する。

```sh
# 初期化が必要な架空機器: reset_transfer は PROTOCOL_PRECONDITION、終了コード 1
kenbi --format=json --safety=demo/safety/protocol-strict.project.json

# 初期状態が ready である架空機器: 両関数が conditional、終了コード 0
kenbi --format=json --safety=demo/safety/protocol-reset-ready.project.json
```

この例が示すのは、コードや機器別注釈を変更せず、仕様で状態制約を変更できること。
実機がその仕様どおり動くという前提の検証や、DMA の受け入れ試験を完了した意味ではない。
