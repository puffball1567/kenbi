# 可視関数の入口・出口契約（実装済み）

`source-function-boundaries.c.v1` は、呼び出し元から追跡した状態・借用を使い、
解析可能な C 関数の入口と出口に要求を課す。外付け protocols パッケージの
各 machine に `boundaries` を追加する。ライブラリ本体や関数名に機種固有の注釈を追加する必要はない。

```json
{
  "boundaries": [
    {
      "symbol": "c:@F@begin",
      "argument": 1,
      "entry": {"state": "ready", "borrow": null},
      "exit": {"state": "busy", "borrow": {"argument": 2, "mode": "read"}}
    },
    {
      "symbol": "c:@F@complete",
      "argument": 1,
      "entry": {"state": "busy", "borrow": {"argument": 2, "mode": "read"}},
      "exit": {"state": "ready", "borrow": null}
    }
  ]
}
```

これは machine 内の抜粋。`states`, `initial`, `terminal`, `operations` は既存の仕様と併用する。
`argument` は対象リソースを指す引数の1始まり番号。
entry と exit の state はその machine に宣言した状態。
borrow は必須で、`null` が「この machine とリソースに結び付く借用なし」、
オブジェクトが「指定引数と同じ記憶領域を指定 mode で借用中」を意味する。
他リソースの借用が存在しないという意味ではない。

例えば begin の本体が外部 transfer_start を呼ぶ場合、Kenbi は次を行う。

1. caller の実際の状態が ready で、このリソースに借用がないことを確認する。
2. begin の本体を解析する。既存の外部操作契約、アクセス制約、寿命検査を省略しない。
3. 正常に戻るすべての解析経路で、状態が busy、借用先が第2引数の記憶領域で、mode が read であることを確認する。
4. 本体で得た実際の状態と借用を caller に戻す。事後条件で状態を上書きしない。

借用を終了せず保持して戻る契約も、entry と exit に同じ借用を指定して表現できる。
別のバッファを借りた本体、終了せずに戻る経路、ローカルバッファを借用させたまま戻る本体は検出する。
関数境界に契約を書いても借用終了・寿命延長・参照の生成にはならない。

## 厳密な入力と診断

- 未知キー・状態・mode、不正な引数番号、entry/exit/borrow の欠落を入力エラーにする。
- 同一シンボル・同一 machine・同一リソース引数の boundary 重複は競合。
  異なる引数や machine の境界は後述のとおり合成できる。外部 protocol operation と同じシンボルは競合。
- 定義・呼び出しに一致しないシンボルは入力エラー。
- `BOUNDARY_PRECONDITION_MISMATCH`: caller の状態・借用が入口契約に不適合。
- `BOUNDARY_POSTCONDITION_MISMATCH`: 本体から戻る経路の状態・借用・寿命が出口契約に不適合。
- `UNKNOWN_BOUNDARY_ARGUMENT`: 引数の由来や対応を確立できず未検証。
- `BOUNDARY_BODY_UNAVAILABLE`: 本体がない関数を boundary だけで扱おうとしているため未検証。
- `MISSING_BOUNDARY_PROTOCOL`: 呼び出す関数の boundary に必要な machine が profile に含まれず未検証。

境界診断は対象関数の定義位置と呼び出し経路を示し、適用した境界仕様の出典・引数・入口/出口条件も記録する。
結果の `functionBoundaries` は適用可能な仕様の一覧であり、全関数の普遍的適合証明一覧ではない。
実際の検証対象と分類は obligations および findings を参照する。
この契約自体は外部前提を新しく作らない。本体内の外部操作に依存すれば従来どおり conditional となる。

## 現在の対応範囲

呼び出し元のローカル由来を追跡できる、可視関数への直接呼び出しが対象。
別翻訳単位の本体、引数経由の別名、read/write モード、分岐と早期 return に対応する。
部分領域は既存の借用解析と同様に記憶領域全体として扱う。
関数が戻ること自体や、最大処理回数・時間は証明しない。

各境界は一つの machine/resource を対象とし、共通の入口契約と正常復帰時の出口契約を持つ。
一つの関数には複数の境界を合成できる。
出口は無条件または後述する int の zero/nonzero 別条件に対応する。
所有権/ヒープ由来との統合、
グローバル由来、ブロック入口・出口、独立した IRQ/コールバックへの受け渡しは未対応。
既存の外部 operation の結果別遷移と併用できる。無条件の exit は両結果の復帰経路に適用する。

caller 情報なしで boundary 付き関数自体を検証ルートに選んでも、入口の資源を勝手に生成しない。
現在は `UNKNOWN_BOUNDARY_ARGUMENT` として未検証になる。
任意の適合入力に対する単独の関数証明、未使用 boundary の全本体検証は未実装。
外部 operation の契約適合や、既存 accesses 契約付き本体の適合を証明済みに昇格させる機能でもない。

テスト: `python3 tests/run_tests_boundaries.py`。
仕様・C フィクスチャは独自作成の架空 API。外部仕様やコードの転載、依存追加はない。


## 戻り値別の出口契約（実装済み）

`source-boundary-results.c.v1` は、実際の本体が返した `int` の zero/nonzero を使い、
対応する出口要求を検査する。無条件の `exit` に代えて `outcomes` を指定する。

```json
{
  "symbol": "c:@F@begin",
  "argument": 1,
  "entry": {"state": "ready", "borrow": null},
  "outcomes": [
    {"result": "zero", "exit": {"state": "busy", "borrow": {"argument": 2, "mode": "read"}}},
    {"result": "nonzero", "exit": {"state": "ready", "borrow": null}}
  ]
}
```

共通の入口要求に加え、成功なら借用を開始し、失敗なら開始しないことを本体に要求できる。
完了ヘルパーには、成功なら借用なし、失敗なら元の借用を保持する出口を記述できる。
どちらの値が成功を意味するかはモデル次第であり、非ゼロ成功にも対応する。

zero と nonzero の両方を一度ずつ指定することが必須。無条件 exit との混在、
片方の欠落、未知カテゴリ、重複、未知キー、不正な状態・借用は入力エラー。
本体の解析結果に応じて対応する出口を検査する。契約に適合するような戻り値や状態を捏造しない。
外部呼び出しの結果を無視して常に成功・失敗を返す本体は、実際の状態がその出口に適合しなければ違反。
呼び出し元も本体で追跡した実際の戻り値と状態・借用を受け取るため、
出口契約に書いたことだけで未完了の借用を終了させることはない。

`return try_start(...)`、int ローカル経由、結果に応じた明示的な return 0/1、
ネストしたヘルパー、別翻訳単位の本体を扱える。
`UNSUPPORTED_BOUNDARY_RESULT` は非 int の関数など未対応の結果型を示す。
`UNKNOWN_BOUNDARY_RESULT` は解析経路の戻り値カテゴリが不明で、出口を選択できないことを示す。
たとえ両カテゴリの出口が同じでも、追跡していない戻り値を既知として扱わず未検証を残す。
キャスト等の未対応構文は従来どおり `UNSUPPORTED_PROTOCOL_MODEL` になる。
既知の int 引数は[結果情報の伝播](configured_protocol_results.md#int-引数による結果の伝播実装済み)を利用する。
未知の入力値、一般の整数値域やエラーコード別の契約は対象外。
不一致診断には `returnResult` と適用した boundary の outcomes を記録する。

この機能でも caller 情報なしの単独関数証明、本体なしAPIの境界適合、終了性・時間上限は証明しない。
テストは `python3 tests/run_tests_boundary_results.py`。
架空 API・仕様・C フィクスチャは独自作成で、依存追加や外部資料の取り込みはない。


## 複数リソースの境界合成（実装済み）

`source-boundary-composition.c.v1` は、同じ関数に対する複数の境界要求をすべて検査する。
既存の boundaries 配列に同じ symbol を持つ項目を追加する。例えば第1・第3引数の
二つのリソースに対して、次のように借用開始を要求できる。

```json
[
  {
    "symbol": "c:@F@pair_begin", "argument": 1,
    "entry": {"state": "ready", "borrow": null},
    "exit": {"state": "busy", "borrow": {"argument": 2, "mode": "read"}}
  },
  {
    "symbol": "c:@F@pair_begin", "argument": 3,
    "entry": {"state": "ready", "borrow": null},
    "exit": {"state": "busy", "borrow": {"argument": 4, "mode": "read"}}
  }
]
```

同一 machine の異なるリソース引数、異なる machine、異なる protocols パッケージからの
境界を合成できる。すべての入口要求を同じ呼び出し前の状態で照合し、本体を一度解析した後、
各復帰経路へすべての出口要求を適用する。項目の順序は操作順序や上書き優先順位を意味しない。
無条件 exit と戻り値別 outcomes の境界を併用する場合も、該当する条件すべてが必要。
片方だけ終了した復旧処理、バッファの取り違え、片方を開始したまま失敗を返す処理を検出する。

引数番号が違うことから、実際の資源やバッファが別物とは仮定しない。
同じリソースを渡して二重開始する本体は状態前提違反になり、同じバッファを共有する場合は
既存の read/write 借用規律を適用する。共有 read は可能だが write は競合する。
入口条件を満たしていても、実際の alias による本体内の違反を隠さない。

同一 symbol / machine / resource argument の再定義は、同じ内容でも入力エラー。
別の条件を書いて既存の契約を弱める上書きはできない。
profile に必要な machine が一つでも欠ければ `MISSING_BOUNDARY_PROTOCOL` となる。
各不一致診断の boundary には、該当 machine・引数番号・仕様の出典を記録する。
複数の違反を一つに潰さず、どちらの資源が不適合かを識別する。

機械可読結果の `functionBoundaries` は symbol から境界配列への対応に統一した。
単一境界の場合も長さ1の配列になる（従来の単一オブジェクト形式からの変更）。
診断の `boundary` は従来どおり該当する一つの境界で、特定境界によらない診断には
`boundaries` として全項目を記録する。終了コード・四分類は変わらない。

この合成は、caller の実際の状態に対する要求検査を拡張するもので、
未知の入口リソースの生成や、関数単独の普遍的適合証明を行うものではない。
IRQ/コールバック・ヒープ/所有権統合の対応範囲も変更しない。
ブロック指定は[囲む関数の追跡](configured_protocol_blocks.md)で対応し、独立したブロック境界契約は未対応。
テストは `python3 tests/run_tests_composition.py`。架空 API と仕様を独自に作成し、
外部資料の転載や依存追加はない。
