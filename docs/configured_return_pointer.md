# 引数由来のポインタ返却契約

外付けAPI契約に `returnPointer: {"argument": 1}` を指定できる。
これは「第1引数と同じ記憶領域の同じ位置を返す」という契約で、所有権移譲ではない。
任意の固定バイト変位はbyteOffsetで指定できる（省略時0）。
型・ABIを問わず任意のビット列を有効なポインタへ変換する宣言ではない。

```json
{
  "symbol": "c:@F@view",
  "effects": [],
  "accesses": [],
  "preservesProtocols": true,
  "assumption": "view.behavior",
  "returnPointer": {"argument": 1}
}
```

通常のcontractsパッケージのfunctions要素に置く。引数番号は既存契約と同じ1始まり。
未知のキー、不正な型、0/負の番号は設定エラー。関数の戻り型がポインタでない場合や
引数が存在しない場合は `POINTER_RETURN_ARGUMENT_MISMATCH` / unverified。
APIの実際の副作用はeffects/accessesへ宣言し、returnPointerで省略しない。

## 追跡する内容

- 呼び出し時の起源、容量、オフセット、配置を戻り値へ引き継ぐ。
- 読み取り専用領域、既存の非同期借用、呼び出し元での寿命終了を維持する。
- 外部API自身のrelease/relocateで失効した領域は返却できない。
- 起源/位置が未確立なら `UNKNOWN_POINTER_RETURN_CONTRACT`、範囲外なら
  `MEMORY_POINTER_RANGE`、失効なら `EXPIRED_BORROW_ORIGIN` とする。
- ポインタ値の返却自体をバッファのread/writeとは扱わない。後続アクセスを別途検査する。

この契約を含む設定では、状態機械やmemoryAccessがなくても順序付き解析を実行する。
ソース中の通常のread/write自体の検証には引き続きmemoryAccessを指定する。
結果のcontractsに適用したreturnPointerを記録し、契約ファイルの入力ハッシュも保持する。
能力識別子は `source-return-pointer-contract.c.v1`。

## 前提と実装適合性

外部実装では契約のassumptionに依存するため、正常系もconditional。
acceptedAssumptionsにない前提では終了コード1で受け入れを拒否する。
注釈だけを理由にverifiedへ昇格させない。

可視本体では解析を実行し、返却起源と位置が指定引数に一致し、寿命が残ることを確認する。
違う領域や位置を返したら `POINTER_RETURN_CONTRACT_MISMATCH`、情報不足なら
`UNKNOWN_POINTER_RETURN_CONTRACT` とする。別翻訳単位にも適用する。
可視本体へのaccesses契約の完全な適合確認は従来どおり未対応で、指定時は
`MEMORY_CONTRACT_BODY_UNVERIFIED`を出す。returnPointerの適合確認と混同しない。

## 対応範囲

固定byteOffsetの引数由来参照のみ。動的な返却オフセット、結果によって異なる副作用/状態遷移、
ヒープ所有権の返却、外部コールバックやIRQへの借用移譲は未対応。
null引数は起源未確立として受け入れない。プロトコル操作との同時指定は設定エラー。
可視関数でのポインタ結果の取り扱いは[ポインタ束縛](configured_pointer_bindings.md)を参照。

回帰: tests/c/t278_return_pointer_contract.c と tests/run_tests_return_pointer_contract.py の33ケース。
すべて独自作成で、外部ライブラリ・デバイス仕様の転載や新規依存はない。

## 固定バイト変位（2026-09-21）

`returnPointer: {"argument": 1, "byteOffset": 4}` は、第1引数の位置から4バイト先を返す契約。
要素数ではない。負の値は手前への移動で、省略時は従来の同位置返却。
許容値は-1000000000〜1000000000の整数。bool、文字列、浮動小数、null等は設定エラー。
結果の適用契約にもbyteOffsetを記録する。能力識別子は `source-return-pointer-offset.c.v1`。

元の引数のオフセットへ加算する前に範囲を検査し、範囲外ならMEMORY_POINTER_RANGE。
元の引数が既に範囲外の場合も、負の変位によって有効な値へ戻したとは扱わない。
末尾の次の位置は形成できるが、その参照先アクセスは別途拒否する。
容量・配置の検査は移動後の位置を使う。型付きポインタでも単位はバイトのため、
型の配置に合わない位置へのread/writeはSOURCE_ACCESS_ALIGNMENT等で拒否される。

可視本体は「引数位置 + byteOffset」と返却位置を照合する。符号付き整数の加算前に
残り容量/先頭までの距離と比較し、検査器内の算術オーバーフローを避ける。
起源・権限・寿命・借用は移動前と同じ領域に結び付いたまま。

追加回帰: tests/c/t279_return_pointer_offset.c / tests/run_tests_return_pointer_offset.py の30ケース。

## nullを返し得る契約（2026-09-21）

`returnPointer: {"argument": 1, "byteOffset": 0, "nullable": true}` は、指定した参照または
nullを返すAPIの契約。nullableはbooleanのみで、省略時false。結果にもこの値を記録する。
能力識別子は `source-nullable-pointer-contract.c.v1`。

外部呼び出しは参照経路とnull経路に分かれ、初期化・コピー・再代入・ヘルパーの引数/返却を
通して追跡する。nullを確認しない参照先アクセスはNULL_POINTER_ACCESSとなる。
if(p)/if(!p)/0との比較で分岐できるが、再呼び出し後に古い判定を使い回さない。
null経路も早期return、状態の終端、借用終了を検査し、失敗時の後処理漏れを許可しない。

effects/accessesは両経路に共通して適用する。nullableは「null時には副作用がない」という
宣言ではなく、既存借用を暗黙に終了させない。プロトコル操作との同時指定も未対応のまま。
指定引数の領域と返却位置は確立している必要があり、null引数の許容は別の契約となる。

可視本体ではnullable=trueならnull返却を許可し、参照を返す各経路は従来どおり
起源とbyteOffsetを照合する。nullable=falseで既知のnullを返した場合は
POINTER_RETURN_CONTRACT_MISMATCH / violation。未知の返却起源をnullと仮定しない。
外部実装は従来どおりconditionalで、受け入れていない前提では終了コード1。

追加回帰: tests/c/t282_nullable_pointer_contract.c / tests/run_tests_nullable_pointer_contract.py の30ケース。
