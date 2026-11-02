# 状態に応じた操作制約（実装済み）

`source-state-effects.c.v1` は、追跡中の protocol 資源の状態に応じて操作を禁止する。
各 machine の `forbidWhile` に、状態名から禁止効果配列への対応を記述する。

```json
{
  "id": "lifecycle",
  "states": ["new", "preparing", "running", "stopped"],
  "initial": "new",
  "terminal": ["new", "stopped"],
  "forbidWhile": {
    "running": ["heap_allocate", "block", "wait", "recurse"]
  },
  "operations": [
    {"symbol": "c:@F@phase_begin", "argument": 1, "from": ["new", "stopped"], "to": "preparing"},
    {"symbol": "c:@F@phase_seal", "argument": 1, "from": ["preparing"], "to": "running"},
    {"symbol": "c:@F@phase_stop", "argument": 1, "from": ["running"], "to": "stopped"}
  ]
}
```

これは protocols パッケージの machine の例。既存の外付け効果契約と、対象 machine を
選択する profile を併用する。この例では初期化中に割り当て可能だが、phase_seal 後は
運用を終了するまで禁止される。running のまま資源の寿命を終える経路も終端状態違反となる。
語彙は状態名と既存の効果だけで、初期化 API や機種名を検査器に固定しない。

## 処理順序と呼び出し

状態・借用と同じ順序付き解析を使い、分岐・ループ・可視ヘルパー・別翻訳単位を追跡する。
呼び出し先の本体が見える場合は本体を解析し、状態遷移前後の順序を保つ。
例えば helper 内で phase_stop してから割り当てる処理を、入口で割り当てたとは扱わない。
一方、phase_seal してから割り当てるヘルパーは拒否する。

外部呼び出しの効果は、その呼び出し入口の状態で検査する。
遷移先の状態を先取りして、その操作自身の禁止効果を免除しない。
phase_stop 自身に heap_allocate があれば、この例ではまだ running なので違反となる。
既知の malloc 等も heap_allocate を持ち、空の外部 effects で隠せない。
外部APIが実際に宣言効果・状態遷移に従うことは明示的な外部前提であり、結果は conditional。
契約欠落や未対応構文を検証済みへ昇格させない。

同じ状態機械の複数リソースや、複数状態機械が有効なら、禁止条件はすべて適用する。
一つの資源を停止しても、別の資源が running なら禁止は残る。
可視再帰の呼び出しでも recurse 制約を確認するが、状態解析の再帰未対応は引き続き未検証。

## 有効範囲と厳密な仕様

これは追跡する資源の状態・寿命に結び付く制約であり、暗黙のプログラム全体のフェーズではない。
明示的な操作で資源を登録・遷移させた後の状態に適用する。
初期状態のままではどの変数がこの資源かを識別できないため、initial への非空の禁止指定は
入力エラーにする。禁止状態へ遷移する操作を定義して使用する。
未知の状態・効果、重複効果、型違いは入力エラー。空配列はその状態の追加禁止なし。

資源の寿命が終了すると、その資源による制約も終了する。
運用中に制約を消してよい仕様にしないため、例では running を terminal に含めず、
明示的な終了操作を要求している。terminal や状態遷移は実際のライフサイクルと整合させる必要がある。
関数外・別実行文脈を含めたアプリケーション全体の「初期化後禁止」の保証には、
その範囲を覆う資源・境界・文脈モデルが別途必要。局所的な制約を全体保証とは扱わない。

profile や context の静的な forbid と併用した場合、そちらの禁止も引き続き適用する。
静的な heap_allocate 禁止を状態仕様で解除することはできない。
ブロック指定で protocol を検査する場合は、既存の protocolScope（囲む関数）で状態制約を適用する。

## 診断と残作業

`STATE_FORBIDDEN_EFFECT` は違反操作の位置・呼び出し経路を示す。
`stateRequirement` に protocol、状態、resourceOrigin、効果、仕様ファイルを記録する。
結果の protocolSpecifications に適用した forbidWhile を含める。

ヒープ容量・プール枯渇・スタック量・ループ回数・処理時間の上限、
グローバルな初期化状態、IRQ/コールバックへの状態移譲や物理デバイスの状態を証明する機能ではない。
テストは `python3 tests/run_tests_state_effects.py`。
C と仕様は独自作成の架空 API であり、外部コード・ベンダー資料の転載や依存追加はない。
