# ソース中の読み書きの範囲・整列検査

profileに `"memoryAccess": true` を指定すると、順序付きC解析で `p[i]` / `*p` 等の
直接アクセスを必須検査する。状態機械や禁止効果と併用でき、単独のprofileも作れる。
false・非booleanは設定エラー。継承先でこの要求を削除できない。

```json
{"profiles":{"driver":{"memoryAccess":true}}}
```

Clangの型サイズ・整列要求、既存のストレージ起源・残り容量・オフセットを照合する。
添字を要素幅でスケールし、アクセス幅が残り容量を超える場合は `SOURCE_ACCESS_RANGE`。
one-pastポインタの形成と、そこから実際に読み書きすることを区別する。
一度範囲外に出て戻った計算も拒否する。動的添字など位置が不明な場合は
`UNKNOWN_SOURCE_ACCESS_RANGE`。不整列・配置保証不足はそれぞれ
`SOURCE_ACCESS_ALIGNMENT` / `UNKNOWN_SOURCE_ACCESS_ALIGNMENT`。

読み取り専用、寿命終了、借用競合、状態資源への未モデル化変更は従来どおり先に検査する。
未知の起源は `UNKNOWN_BORROW_ORIGIN` のまま未検証。グローバルの読み取りも
局所起源がないことを理由に検査から省略しない。
別名・再代入・可視ヘルパー・別翻訳単位・分岐・whileの経路を追跡する。
ブロック指定では囲む関数全体の範囲・前提を `protocolScope` に記録する。

外部呼び出しには完全なaccesses契約が必要。外部動作は明示された前提であり、
外部API内の全アクセスをこのソース検査で証明するわけではない。
外部APIの容量/整列条件はaccesses.minBytes/alignmentで指定する。
可視本体のメモリ契約適合は従来どおり未検証を維持する。

capabilityは `source-memory-access.c.v1`。obligationの `sourceMemoryAccess` に有効化を、
`sourceAccesses` にアクセス幅・要求配置・残り容量・位置・判定・呼び出し連鎖を記録する。
単位はc-sizeof-bytes。失敗診断には `capacityRequirement` に同じ証拠を付ける。
起源・寿命等の先行検査で停止したアクセスには範囲証拠が付かない場合がある。

動的添字の値域証明、一般のキャスト、フィールド/部分領域、ヒープ、グローバル、
volatile/atomic・MMIOは対応範囲外。未対応は未検証であり、物理アクセス幅やDMA領域の保証ではない。
既存のprofileにこの指定がなければ、状態/借用やAPI契約の検査範囲を維持する。

回帰: `python3 tests/run_tests_source_access.py`。
C/JSONと実装は独自作成で、外部コード・仕様・依存の追加はない。

## ポインタ形成時の範囲検査（2026-09-20）

memoryAccess有効時は、対応するポインタの+/-、&p[i]の形成時にも範囲を検査する。
`source-pointer-formation.c.v1` とobligationの `pointerFormations` に判定根拠を記録する。
先頭からone-pastまでの形成を許可し、その範囲外は `SOURCE_POINTER_RANGE`。
動的オフセット・未知起源・null由来などは `UNKNOWN_SOURCE_POINTER_RANGE` として拒否する。
失効した起源からの演算は `EXPIRED_BORROW_ORIGIN`。

形成した値を未使用にする場合や、引数を使わないヘルパーへ渡す場合にも検査する。
範囲外へ出てから戻す式は、中間の形成時に拒否する。従来は後続アクセス時に
SOURCE_ACCESS_RANGEとなっていた一部の例は、より早い形成時の診断になる。

アドレス計算自体は参照先の読み書きではないため、持続借用とのアクセス競合を
捏造しない。排他的借用中に有効範囲内のアドレスを計算しても許可するが、
実際にそのポインタから読み取る場合は既存の借用競合検査を実行する。

これは対応する形成式の検査であり、一般のポインタ差・比較・キャストや
部分オブジェクト境界のモデルを新たに実装するものではない。
回帰: `python3 tests/run_tests_pointer_formation.py`。
`tests/c/t269_pointer_formation.c` と追加C/JSONは独自作成で、外部コード・依存追加なし。

## 未検証のポインタ差を受理しない（2026-09-21）

memoryAccess有効時、ポインタ同士の減算を単なる副作用のない整数式として通さない。
修正前に、別々の自動配列の差を未使用変数へ格納する例がverifiedになることを再現した。

- 既知の異なる起源: POINTER_DIFFERENT_STORAGE（違反）。
- 失効した起源: EXPIRED_BORROW_ORIGIN（違反）。
- 同じ起源や未知起源: UNSUPPORTED_POINTER_DIFFERENCE（未検証）。

同じ領域でも配列要素型・部分領域境界・ptrdiff_tでの結果の表現可能性を証明していないため、
完全対応とはしない。診断のpointerDifferenceに両起源を記録し、未知はnullとする。
capabilityはsource-pointer-difference-gate.c.v1。通常の整数減算や、定数による
短絡で評価されない式をこの拒否対象へ広げない。既存の効果/状態のみのprofileは範囲を維持する。

回帰: `python3 tests/run_tests_pointer_difference.py`。
`tests/c/t270_pointer_difference.c` と追加C/JSONは独自作成。外部コード・仕様・依存追加なし。

## ポインタ比較の検査範囲（2026-09-21）

memoryAccess有効時、<・>・<=・>=によるポインタの順序比較は
UNSUPPORTED_POINTER_ORDERとして未検証にする。修正前に別領域の順序比較が
無検査でverifiedとなる例を再現した。配列/部分オブジェクトと対象言語の規則を
扱う専用の検証が未実装であるため、同一起源でも順序を保証しない。

==・!=には同じ拒否を適用しない。異なる領域の等値比較やnull確認は維持する。
ただし、順序/等値のいずれも、既知の失効起源を使用する場合はKenbiの寿命規律に従い
EXPIRED_BORROW_ORIGINで拒否する。未知起源を有効と証明したり、比較結果を推論して
分岐を取り除く機能を追加するものではない。

診断のpointerComparisonに演算子・両起源を記録する。
capabilityはsource-pointer-comparison-gate.c.v1。整数比較や定数短絡によって
評価されない比較は拒否対象にしない。memoryAccess未指定のprofileは従来の範囲を維持する。

回帰: `python3 tests/run_tests_pointer_comparison.py`。
`tests/c/t271_pointer_comparison.c` と追加C/JSONは独自作成。外部コード・仕様・依存追加なし。

## ポインタ値の寿命検査（2026-09-21）

`memoryAccess: true` では、ポインタ変数の値を読む時点で既知の失効起源を検査する。
コピー初期化・再代入右辺・`!p`・if/while 条件・未使用仮引数への引き渡しでも
`EXPIRED_BORROW_ORIGIN` / violation とする。参照先への read/write がない場合にも適用する。
能力識別子は `source-pointer-value-lifetime.c.v1`。

代入左辺、`&p` によるポインタ変数自身のアドレス取得は、保存されているポインタ値の
読み取りではない。有効な領域への再代入を許可し、定数の短絡評価で実行されない右辺も
失効参照の使用には数えない。未知起源や null の値の判定だけで領域アクセスの安全性を
証明したとは扱わず、後続アクセスは従来の容量・配置・借用検査へ渡す。
これは既知の寿命終了を扱う検査で、未初期化ポインタや一般の値表現の証明は含まない。

回帰: `tests/c/t272_pointer_value_lifetime.c` と
`tests/run_tests_pointer_value_lifetime.py`（別翻訳単位を含む17ケース）。

## 同じ型への明示的ポインタキャスト（2026-09-21）

C形式の明示的キャストで、変換前後がともにポインタ型かつClangの正規化した型が
`clang_equalTypes` で一致する場合、元の起源・容量・オフセット・配置・権限を維持する。
typedefによる別名、括弧、重ねた同型キャスト、配列から同じ要素型ポインタへの変換を含む。
能力識別子は `source-identity-pointer-cast.c.v1`。順序付き解析全体で適用するため、
直接アクセスだけでなく外部APIの容量/配置要求、状態機械の非同期借用にも接続される。

キャストを挟んでも範囲外、寿命切れ、読み取り専用領域への外部write、借用競合を検出する。
型が同じことは、元のポインタ値や参照先が安全である証拠ではない。
整数との相互変換、異なる要素型への変換、const除去は引き続き
未対応として拒否する（voidポインタから文字型ポインタへの変換は下記）。volatile/atomicアクセス、間接関数呼び出しも対応済みとはしない。

回帰: `tests/c/t273_identity_pointer_cast.c` と
`tests/run_tests_identity_pointer_cast.py`（30ケース）。独自作成の入力のみを使用。

## 関数復帰時のポインタ寿命（2026-09-21）

`memoryAccess: true` では、ポインタ返却式の起源をスコープ退出・値引数の寿命終了まで
保持する。復帰時にその起源が失効する場合は `EXPIRED_POINTER_RETURN` / violation。
ローカル配列、別名、オフセット、入れ子スコープ、値引数のアドレスを含む。
返却式の評価時点で既に失効している場合は従来の `EXPIRED_BORROW_ORIGIN` を使う。
能力識別子は `source-pointer-return-lifetime.c.v1`。

呼び出し元の生存する領域を返すヘルパーと、整数リテラル0によるnull返却は受理する。
起源が確立していないポインタの返却は `UNKNOWN_POINTER_RETURN` / unverified。
この検査は復帰時点の寿命を扱う。可視関数の戻り値の束縛は
[ポインタ束縛](configured_pointer_bindings.md)の追加実装を参照。
外部の返却借用契約やヒープ所有権移譲全体は未実装。

回帰: `tests/c/t275_pointer_returns.c` と `tests/run_tests_pointer_returns.py`（16ケース）。
フィクスチャのClang return-stack-address警告だけを無効化し、Kenbi自身の経路検査を
確認する。Kenbiの検査抑制注釈は使用しない。

## 左右を入れ替えたポインタ演算（2026-09-21）

`n + p`、`n[p]`、`&n[p]` を、型を確認して既存のポインタ/添字モデルへ接続する。
起源・型サイズ・オフセット・容量・配置・権限・寿命を `p + n` / `p[n]` と同様に検査する。
能力識別子は `source-commuted-pointer.c.v1`。引数渡し、ポインタ返却、read/write、
借用中のアドレス計算にも適用する。演算子の左右を変えても範囲外や借用競合を許可しない。

正規化するのはポインタと整数の組のみ。減算の左右は入れ替えず、ポインタ同士の差は
従来の専用検査に渡す。元の式にある読み取りの検査は維持し、副作用や呼び出しを
並べ替えて受理することはしない。動的な添字の値域証明は未対応のまま。

回帰: `tests/c/t277_commuted_pointer.c` / `tests/run_tests_commuted_pointer.py`（25ケース）。
不正な定数添字の例ではClangのarray-bounds警告だけを無効化して、Kenbi自身の検査を確認する。

## 固定sizeof / _Alignof（2026-09-21）

固定の組み込み型を指定した `sizeof(int)` / `_Alignof(long double)`、変数に対する
`sizeof a`、直接ポインタ変数の参照先型を調べる `sizeof *p` を扱う。
Clangがコンパイル条件・ターゲットに基づいて確定した正の整数値だけを使用し、
ポインタ形成、添字、+=/-=にも接続する。32/64ビットターゲットでsizeof(void*)の
違いを反映する。能力識別子は `source-fixed-type-query.c.v1`。

受理した型照会は未評価オペランドのreadや呼び出しを発生させない。
そのためsizeof *pはpの参照先アクセスではなく、sizeof aもaの借用と競合しない。
効果解析と順序付き解析は同じ受理判定を使用する。

VLA、実行時の型境界、副作用を含む型名、関数呼び出しを含むオペランド、マクロ、
任意のtypedef型名や複雑な式は未対応として拒否する。
sizeof(int)+1等の一般の定数式の値域証明は追加せず、既存の不明なオフセット扱いを維持する。

回帰: tests/c/t280_fixed_type_query.c / tests/run_tests_fixed_type_query.py（24ケース）。

## 既知のnull値の追跡（2026-09-21）

整数リテラル0から作るポインタのnull情報を、ローカル束縛、コピー/再代入、
可視関数の値引数と戻り値へ引き継ぐ。別名は独立した束縛として更新し、
一方への再代入で他方のnull情報を消さない。スコープ退出、分岐、ループ、別翻訳単位にも対応。
能力識別子は `source-null-pointer-tracking.c.v1`。

memoryAccessでは、既知のnullへのアクセスを `NULL_POINTER_ACCESS`、形成/更新を
`NULL_POINTER_ARITHMETIC` / violation とする。情報不足によるunverifiedとは区別する。
ポインタ変数を使ったif/while等の条件、否定、0との等値/非等値では、追跡済みの
nullと、既知の生存領域の有効位置を区別して経路を選ぶ。

起源不明の引数をif(!p)で除外しただけでは容量・配置・寿命を証明したとは扱わない。
直接条件内のポインタ返却呼び出しや一般のnullマクロ/明示的変換、
関数呼び出しや更新を含む短絡式は別の継続課題。対応する読み取り式は後述の短絡検査を参照。
nullを返し得る外部契約は[返却契約](configured_return_pointer.md)の追加実装を参照。
外部APIのnull引数の許容条件は追加せず、APIアクセス/返却契約では従来の制約を維持する。

回帰: tests/c/t281_null_pointer_tracking.c / tests/run_tests_null_pointer_tracking.py（24ケース）。
既存のnull参照・演算5ケースは、不明な起源から具体的なnull違反へ期待値を変更した。

## 経路ごとの短絡アクセス検査（2026-09-21）

対応する読み取り式の `&&` / `||` では、まず左辺を検査し、その真偽に応じて右辺の
アクセス検査を実行する。`p && *p`、`p == 0 || p[0]` 等のnullガードを認識する。
能力識別子は `source-short-circuit-access.c.v1`。

nullable外部契約の参照/null経路、コピー、ヘルパー、別翻訳単位、入れ子の短絡式、
while/do/for条件にも適用する。右辺を実行する場合は従来の容量・配置・寿命・借用を検査し、
左辺自体の不正アクセスを省略しない。左右の真偽が不明なら必要な両経路を検査する。

これは対応済みの読み取り式の評価順序を扱う拡張。短絡式中の直接呼び出しは後述の追加実装を参照。更新演算子は
未対応のまま。起源不明のポインタのnullチェックから容量や寿命を推定しない。

回帰: tests/c/t283_short_circuit_access.c / tests/run_tests_short_circuit_access.py の24ケース。

## 整数値を選ぶ条件演算子（2026-09-21）

整数/列挙値を返す読み取り専用の `condition ? yes : no` を経路ごとに検査する。
条件の読み取りを先に検査し、追跡済みの真偽に従って選ばれる側を実行する。
不明な条件は両経路を検査する。`p ? p[0] : 0` 等のnullガード、nullable外部契約、
入れ子/短絡式、while/do/for、別翻訳単位のヘルパーにも適用する。
能力識別子は `source-conditional-access.c.v1`。

int結果では既存のzero/nonzero情報を条件付きで引き継ぎ、代入後のif等へ渡す。
一般の数値や値域の推論は追加せず、int以外への変換の安全性も仮定しない。
ポインタ型の条件式の初期化/代入/returnは[ポインタ束縛](configured_pointer_bindings.md)の追加実装を参照。
intの分岐内呼び出しは後述の追加実装を参照。更新演算子は未対応。
条件自体のnull参照、実行側の範囲外や借用競合は引き続き拒否する。

回帰: tests/c/t284_conditional_access.c / tests/run_tests_conditional_access.py の25ケース。

## int条件式内の直接呼び出し（2026-09-21）

intを返す?:では、条件部・分岐内の対応済み直接呼び出しを順序付き解析へ接続する。
条件の結果で選ばれる側だけを実行し、その側のzero/nonzero結果を明示的に保持する。
一方の呼び出し結果が別の分岐や後続呼び出しの結果と混同されないようにする。
能力識別子は `source-conditional-calls.c.v1`。

初期化・代入・return・if/ループ条件、入れ子、可視ヘルパー/別翻訳単位で使用できる。
状態・借用は呼び出しと同じ経路に保持するため、開始しなかった資源の終了、開始後の
後処理漏れ、選択側の範囲外アクセスを検査する。外部関数は既存の効果/アクセス/状態契約を
引き続き必要とし、式内呼び出しを検査の抜け道にしない。

ポインタ条件式の分岐内呼び出しは[ポインタ束縛](configured_pointer_bindings.md)の追加実装を参照。
更新演算子や一般の副作用式はこの拡張に含めない。数値結果は既存のzero/nonzeroの範囲で、一般の値域保証ではない。

回帰: tests/c/t286_conditional_calls.c / tests/run_tests_conditional_calls.py の20ケース。

## 短絡式内の直接呼び出し（2026-09-21）

`&&` / `||` 内の対応する直接呼び出しを順序付き解析へ接続する。
左辺を実行してzero/nonzeroを確認し、必要な経路だけ右辺を実行する。
選択した経路の論理結果を保持して、後続の代入・if・ループ条件・returnへ渡す。
独立した `begin() && end();` のような式文も扱う。
能力識別子は `source-short-circuit-calls.c.v1`。

呼び出しによる状態・借用の変化を同じ経路に維持する。短絡で終了処理を飛ばした場合の
借用終了漏れ、開始せずに終了した場合の前提違反、右辺のアクセス競合を検査する。
可視ヘルパー/別翻訳単位、入れ子、while/do/for条件にも接続する。

外部APIの契約要件や効果禁止の解析範囲は変更しない。
一般の副作用式、更新演算子、一般の値域・ポインタ戻り値の真偽推論の拡張は含めない。

回帰: tests/c/t287_short_circuit_calls.c / tests/run_tests_short_circuit_calls.py の20ケース。

ポインタ返却値を直接条件に用いる場合とその否定は、[ポインタ束縛](configured_pointer_bindings.md)の「ポインタ返却値を用いる条件判定」を参照。

`*view(buffer)` や `*(flag ? p : q)` の整数読み取りは、[ポインタ束縛](configured_pointer_bindings.md)の「ポインタ返却値の直接読み取り」を参照。

返却値/条件式に対する定数添字の読み取りは、[ポインタ束縛](configured_pointer_bindings.md)の「ポインタ返却値の定数添字読み取り」を参照。

返却値/条件式の参照先への定数代入は、[ポインタ束縛](configured_pointer_bindings.md)の「ポインタ返却先への定数書き込み」を参照。

返却値/条件式を基点とする定数加減算は、[ポインタ束縛](configured_pointer_bindings.md)の「ポインタ返却値の定数加減算」を参照。

返却値/条件式の添字位置のアドレス取得は、[ポインタ束縛](configured_pointer_bindings.md)の「ポインタ返却値の添字位置のアドレス取得」を参照。

返却値と整数リテラル0の等値比較は、[ポインタ束縛](configured_pointer_bindings.md)の「ポインタ返却値とnullの比較」を参照。

## voidポインタから文字型ポインタへの明示的キャスト（2026-09-27）

`(unsigned char *)p` のように、`void *` から文字型（char / signed char / unsigned char）への
ポインタへの明示的キャストは、C が暗黙に行う同じ変換の明示形として起源・容量・オフセット・
配置・権限を維持する。文字型は整列要求がなく任意のオブジェクトを参照できるため、
変換自体で新たな未定義動作は生じない。修飾子は追加のみ許し、const / volatile の除去、
_Atomic、文字型以外への変換（例: `(int *)p`）は従来どおり未対応。

`((void *)0)`（`NULL` マクロの一般的な定義）は C11 6.3.2.3 の null ポインタ定数として
整数 0 と同じに扱う。比較全体がマクロ内にある形（`IS_NULL(p)` 等）は未対応のまま。

## 二項演算子の読み取り（2026-10-01）

二項演算子・複合代入の種類は、ソース上で両オペランドの間にあるトークンから読み取る。
両オペランドの境界は同じファイル上になければならない。マクロが生成したオペランドは、
その呼び出し位置を境界とする。右オペランドは呼び出しの開始位置、左オペランドは呼び出しが
識別子1つで、その直後がちょうど演算子である場合に限る（`p == NULL`、`CTRL |= 1u` など）。
演算子自体がマクロ由来の形や、両オペランドが同じマクロ呼び出し内にある形では
該当するトークンが得られず、未対応のまま残る。

回帰: `tests/run_tests_identity_pointer_cast.py`（32ケース）と
`tests/run_tests_allocation.py` の NULL マクロのケース。
