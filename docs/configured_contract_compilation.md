# 外付け契約のコンパイル条件

2026-09-20。`source-contract-compilation.v1` を実装。
contracts / protocols パッケージに任意の `compilation` オブジェクトを指定できる。
指定する場合、次の3フィールドをすべて必須とする。

| フィールド | 意味 |
| --- | --- |
| clangArgs | Kenbiの言語既定値を含む、照合するClang引数列。自動付加される最後のworking-directory引数は含めない |
| directory | 最後のworking-directory引数に対応するディレクトリ。パッケージからの相対パスまたは絶対パス |
| clangVersion | 結果JSONのclangVersionと一致する文字列 |

C入力の既定引数は `-std=c11`、C++入力は `-x`, `c++`, `-std=c++17`。
その後ろにprojectのclangArgsが続く。project側に同じ引数を指定した場合も重複を省かない。
最後に付加する `-working-directory=<directoryの絶対パス>` を含めた列を、
実際にClangへ渡した引数と完全一致で照合する。部分一致や順序の無視は行わない。
既存結果のcompilation[].argumentsとclangVersionを参照して要求を記述できる。

順序を含む完全一致により、後続の `-U` や `-D`、ターゲット指定による上書きを見落とさない。
意味的に等価な引数の並べ替えも一致とは扱わない。レスポンスファイルは未対応として拒否する。
パッケージの全要求を採用した全翻訳単位に適用するため、C/C++混在などで既定引数が
異なる場合も要求を満たさなければ拒否する。翻訳単位別の条件選択はまだ実装していない。

異なるパッケージの要求が相互に異なる場合は競合として拒否する。
extendsによって要求が消えることはない。未知キーや型違い、未指定の必須フィールドも拒否する。
条件不一致は `SAFETY_INPUT_ERROR`、status=unverified、accepted=false、終了コード2。
Clang自体が入力を拒否した場合は、その入力エラーが先に出ることがある。

結果JSONのcontractCompilationにパッケージ・宣言バージョン・契約ファイル、
requiredArguments / requiredClangVersion / requiredDirectory / checkedSourcesを記録する。
観測した引数はcompilation、観測したClangバージョンはclangVersionに記録する。
指定を省略したパッケージの適用条件を推測しない。結果のcontractCompilationが空なら、この条件照合は行っていない。
引数一致によってAPIの動作契約が証明されるわけではなく、外部前提とその受け入れ確認は維持する。

対象はKenbiのソース解析条件。CPU/ABIを固定する場合は明示的なターゲット等の引数を
要求に含める。暗黙のデフォルトターゲット、環境変数、SDK全体やコンパイラバイナリの同一性を
バージョン文字列だけで証明する機能ではない。依存ファイルの内容はartifactsで別途照合できる。
ライブラリを生成した過去のビルド条件、実際のリンク結果、機械語・WCETの対応は未対応。

独自のC/JSONを使用するtests/run_tests_compilation.pyとtests/c/t256_contract_compilation.cで検査。
外部コード・仕様・新規依存の取り込みはない。
