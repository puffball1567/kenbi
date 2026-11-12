# kenbi

[English](README.md) · [简体中文](README.zh.md) · **日本語** · [Español](README.es.md) · [Português](README.pt.md) · [Français](README.fr.md) · [Deutsch](README.de.md)

**kenbi は、C/C++ のコードが宣言したメモリ安全性の規則を守っているかを検査します。** バッファを誰が所有するか、誰が解放するか、借用がいつまで有効かを、コードの横にコメントで書きます。kenbi はそれを静的に、すべての経路について確かめ、コードがコメントどおりに動くかを検査します。コンパイラではなく、ビルドは変えません。

**AI エージェントと C/C++ を書くために作りました。** [MCP サーバ](#ai-コーディングエージェントと使う-mcp)を通して、エージェントは書いたばかりの C/C++ を検査し、指摘が出た理由と直し方を確かめ、検査が何も報告しなくなるまで繰り返します。メモリ安全性は、書いた後のレビューではなく、エージェントが書く流れの一部になります。エージェントが書いた注釈は、kenbi が検査し続ける規則としてコードに残ります。

> ステータス: **v0.1.0**、開発初期段階です。インタフェース、注釈の語彙、
> JSON 出力は今後も変わる可能性があります。

## 最初の例

[`demo/quickstart.c`](demo/quickstart.c):

```c
// @kenbi
#include <stdlib.h>
#include <string.h>

/* @mem app::buf { alloc: malloc, free: free } */

char *dup_name(const char *s) {
  char *p = malloc(strlen(s) + 1);
  if (!p) return NULL;
  strcpy(p, s);
  if (p[0] == '\0') return NULL;  /* leaks p */
  return p;
}
```

```console
$ ./kenbi demo/quickstart.c
demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
── kenbi coverage ───────────────────────────
  memory-relevant functions : 1
  GREEN (contracted)        : 0  (0%)  ← boundaries declared, modular-trust
  verified (no trust residue): 0  (0%)  ← whole closure covered
  adopted (@kenbi)          : 1  (100%)
  RED (needs fixing)        : 1  (separate from coverage — fix these)
```

`@kenbi` はファイルを所有権の検査の対象にし、`@mem` は資源の種類とその確保・解放の方法を宣言します。早期 return を `{ free(p); return NULL; }` に直すと、`ok — no findings from the checks that ran` と出て、終了コードは 0 になります。`checked:` の行はすべての結果に付きます。指摘がないと言えるのは、そこに挙げた検査についてだけです。

## ほかのツールとの違い

- **推測せず、宣言を確かめる。** kenbi はコードの意図を推測しません。注釈が宣言した内容と照らし合わせるので、指摘は怪しく見える形ではなく、書かれた規則からコードが外れている場所です。
- **証明できないものは GREEN にしない。** すべての経路で規則が守られていると示せない場所は指摘として報告し、kenbi が扱えない構文（後ろ向きの `goto` など）も飛ばさずに報告します。指摘のない結果は、kenbi が責任を持って示す結論です。
- **コードを動かさずに、すべての経路を調べる。** sanitizer やテストが見るのは実行された経路だけです。kenbi は、ループ、早期 return、`goto` による後始末、C++ の例外を含めて、すべての経路をたどります。
- **結果は毎回同じで、検査した範囲を示す。** 同じ入力には同じ出力を返し、結果には実行した検査、前提にした契約、指摘を抑えたすべての `@unsafe` を挙げます。
- **少しずつ導入できる。** 検査はそれぞれ個別に、ファイル・関数・ブロック単位で有効にできるので、既存のコードが一面赤になることはありません。

## AI コーディングエージェントと使う (MCP)

[MCP サーバ](mcp/README.md)は、検査の機能と、それを使って直すための材料をエージェントに渡します:

| | エージェントが受け取るもの |
|---|---|
| `check_memory_safety` | kenbi の指摘と、どの検査をどの関数に行ったかを示す要約。そのため「指摘なし」が「安全」と読まれることはない |
| `explain_finding` | 指摘コードまたは CWE 番号に対して、何が原因か、中途半端な修正ではなぜ直らないか、宣言する契約と合わせた修正版 |
| `kenbi://annotations` | 注釈のリファレンス |
| `kenbi://patterns` | kenbi が受け入れる安全な C/C++ の形と、それが拒否する危険な形の対比 |

流れは 書く → 検査 → 説明を聞く → 直す → 再検査 で、終わりを決めるのはモデルではなく kenbi です。サーバは、注釈がすでに言っていることをコメントで繰り返さないようエージェントに指示します。注釈は検査されますが、コメントは検査されないからです。

[`demo/quickstart.c`](demo/quickstart.c) での流れと、サーバが実際に返した内容です（どの要約のあとにも kenbi の JSON 全体が続きますが、ここでは省いています）:

1. エージェントが `dup_name` を書き、`check_memory_safety` を呼びます:

   ```text
   kenbi: 1 error(s), 0 warning(s) across 1 file(s):
     demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 0 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

2. `LEAK` を指定して `explain_finding` を呼ぶと例が返り、最初の例は修正版で終わります:

   ~~~text
   # Fixing `LEAK`  (CWE-401 · ownership axis · contracts: @mem)
   Intent: free on every path, including early returns. Free obligation skipped on an early-return branch.

   ## A — what triggers it (RED)            …
   ## B — why a half-fix stays RED           …
   ## C — the fix (GREEN)
   ```c
   // @kenbi
   #include <stdlib.h>

   void CWE401_Memory_Leak__branch_early_return_02_fixed(int c)
   {
       /* @mem g::buf { free: free, owner: data } */
       char * data = (char *)malloc(100);
       if (data == NULL) { return; }
       /* FIXED: free on the early-return path too */
       if (c) { free(data); return; }
       free(data);
   }
   ```
   ~~~

3. 早期 return でも `p` を解放するように直し（`if (p[0] == '\0') { free(p); return NULL; }`）、もう一度検査します:

   ```text
   kenbi: no findings in 1 file(s) from the checks that ran. This is not a statement about anything outside the scope below.

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 1 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

[`integrations/agent/`](integrations/agent/) には、Claude Code（`SKILL.md`）、Codex 系のエージェント（`AGENTS.md`）、GitHub Copilot 向けに同じ内容の指示ファイルがあります。

設定方法は [`mcp/README.md`](mcp/README.md#configure-in-an-mcp-client) にあります。

## 検査する内容

検査はそれぞれ個別に opt-in します:

| 軸 | opt-in | 検査内容 |
|---|---|---|
| 所有権 / 寿命 | `@kenbi`（またはマーカーのないファイル） | use-after-free、double free、すべての exit でのリーク、use-after-move、誤った deallocator、ダングリングな return、借用と arena の寿命、宣言コントラクトと関数本体の照合、C++ の RAII owner、スマートポインタ、例外パス |
| null | 常時（`@nullable` / `@nonnull` と併用） | null かもしれない、または null と分かっているポインタのデリファレンス（flow-sensitive な narrowing 付き） |
| 境界 | `@spatial` | バッファに届く信頼できないインデックスやサイズには、存在し・十分で・オーバーフローしない境界チェックが必要。`@counted_by` と、宣言されたデータ構造不変条件（`@invariant` / `@maintains`） |
| 初期化 | `@initcheck` | すべてのパスで代入される前に読まれるローカル変数 |
| タグ付き共用体 | `@typecheck` + `@variant` | タグが証明されていない箇所で使われる共用体メンバ |
| ロック | `@threadsafe` | ロックなしのアクセス、釣り合わないロック、宣言されたロック順序（AB-BA デッドロック） |
| 低レベル性質 | `--safety=project.json` | 呼び出し閉包内の禁止された効果、リソースの状態機械、スタックと呼び出しの深さ、メモリ領域、MMIO など。[設定による低レベル検証](#設定による低レベル検証--safety)を参照 |

libclang フロントエンドが実際の C / C++ を（`compile_commands.json` を読んで）typestate
エンジンへ lowering します。ループは有界不動点まで解析され、前方 `goto` クリーンアップ ラダー、
`break` / `continue`、`try` / `catch` はモデル化され、kenbi がモデル化できないものはスキップせずに
報告されます。出力はテキストまたは `--format=json` です。

## クイックスタート

```sh
# Debian / Ubuntu; for other systems see "OS 別 libclang インストール" below.
# Nim 2.2 or later: https://nim-lang.org/install.html
sudo apt-get install libclang1-14 libclang-common-14-dev
git clone https://github.com/puffball1567/kenbi
cd kenbi
nimble build -d:release
./kenbi demo/quickstart.c
```

## 必要環境

- **Nim** >= 2.2（[インストール方法](https://nim-lang.org/install.html)）
- **libclang**（共有ライブラリ。`clang-c` ヘッダは *不要* です —— 起動時に動的ロードする
  ランタイムの `.so` / `.dylib` / `.dll` のみ必要です）。
- **clang の組み込みヘッダ**（`stddef.h`、`stdarg.h` など）。これらを include するファイルを
  libclang が解析するのに必要です。多くの clang/LLVM パッケージではライブラリと一緒に入りますが、
  Debian と Ubuntu では別パッケージ `libclang-common-N-dev` です。

libclang は実行時に soname でロードします。デフォルトの探索リストは
`libclang.so`、`libclang-13..18.so` などをカバーします。ライブラリ名やパスが
異なる場合は、コンパイル時に上書きしてください:

```sh
nimble build -d:release -d:kenbiLibclang=/full/path/to/libclang.so
```

## ビルドとテスト

```sh
nimble build          # produces ./kenbi
nimble test           # mini-format engine suite (no libclang needed)
nimble testc          # libclang suite on real C / C++  (needs libclang)
nimble testsafety     # --safety suites (needs libclang and python3)
nimble testall        # everything

# or directly:
nim c -d:release -o:kenbi src/kenbi.nim
./kenbi path/to/file.c
./kenbi path/to/file.cpp
./kenbi tests/t01_double_free.mc       # mini-format
```

### OS 別 libclang インストール

**Ubuntu / Debian**
```sh
sudo apt-get install libclang1-14 libclang-common-14-dev
# libclang1-14 is the library (/usr/lib/x86_64-linux-gnu/libclang-14.so.1, found by default);
# libclang-common-14-dev holds clang's builtin headers (stddef.h, stdarg.h, ...). Without
# them every file that includes one fails to parse, and kenbi reports it unanalysed (exit 2).
# If unresolved, point at it explicitly:
nimble build -d:release -d:kenbiLibclang=/usr/lib/llvm-14/lib/libclang.so
```

**Fedora / RHEL**
```sh
sudo dnf install clang-libs               # provides /usr/lib64/libclang.so.*
```

**Arch**
```sh
sudo pacman -S clang                      # /usr/lib/libclang.so
```

**macOS**（Homebrew LLVM、または Xcode Command Line Tools）
```sh
brew install llvm
nimble build -d:release -d:kenbiLibclang="$(brew --prefix llvm)/lib/libclang.dylib"
# Apple's Command Line Tools also ship a libclang at
#   /Library/Developer/CommandLineTools/usr/lib/libclang.dylib
```

**Windows**（MSVC + LLVM リリース）
```bat
:: install LLVM from https://releases.llvm.org and ensure libclang.dll is on PATH
nimble build -d:release -d:kenbiLibclang=libclang.dll
```

## 使い方

```
kenbi [--format=text|json] [--compile-commands=PATH] [--project[=PATH]] [--emit-contracts]
      <file> [more...] [-- <extra clang args>]
kenbi [--format=text|json] --safety=project.json
kenbi --version
```

- `kenbi --version` は kenbi のバージョンと、読み込んだ libclang を表示します。
- `*.c *.cc *.cpp *.cxx` → libclang フロントエンド（C か C++ かは拡張子で判定）。
- `*.mc` → mini-format。
- C/C++ ではパースフラグを `compile_commands.json` から取得します。
  `--compile-commands=PATH` で渡すか、ソースファイルから上方向に辿って自動検出します。
  `--` 以降は clang コマンドラインに追加されます。
- `--project[=compile_commands.json]` は、データベースに列挙されたすべての翻訳単位を解析します。
  各ファイルの findings はそのファイル固有のままです（注釈はファイルスコープで、解析も同様です）。
  これが加えるのは **閉包** です: 解析対象の別の単位で定義された関数へのコントラクト付き呼び出しは、
  その単位の判定に解決されます。そのため、依存閉包全体が解析済みかつ GREEN である GREEN は
  *verified* とみなされ、trusted frontier はプロジェクト内のどこでも定義されていないもの
  （バイナリで配布されるライブラリ、OS、FFI 境界）にまで狭まります。パスを省略すると、
  最初に与えたファイルから上方向に辿ってデータベースを探します。
- `--format=json` は安定したコードを持つ機械可読な findings を出力します（CI・
  エディタ・エージェント向け）。`--format=text`（デフォルト）は人間可読です。
- `--safety=project.json` は、
  [設定による低レベル検証](#設定による低レベル検証--safety)で説明する設定済みの低レベル検査を実行します。
- 終了コード: `0` クリーン · `1` 問題あり · `2` 使用法 / パースエラー。


## opt-in の単位: ファイル、関数、ブロック

`@kenbi` は規律の対象を示します —— その外側の findings は捨てられるので、導入は段階的に進められ、
一面が赤になることはありません。マーカーは直下にあるものに結び付きます:

```c
// @kenbi                    ← at the top of a file: every function in it
// @kenbi
void f(void) { … }           ← above a function: that function

void huge(void) {            ← a function too large to clean up at once
  …                          ← neutral, as in any unadopted function
  // @kenbi
  {                          ← above a block or an if/for/while/switch: that statement
    char *p = malloc(8);     ← checked
  }
  …                          ← neutral again
}
```

規律下のブロックは、それを含む関数を規律下に置く **わけではありません**: そうしたブロックは独立して
数えられて専用の行（`blocks adopted`）で報告され、採用済み関数の数に合算されることはありません。

## ライブラリ向けのコントラクトを配布する

コントラクトのオーバーレイはコメントだけのファイルです —— ライブラリと並べて公開することも、
kenbi を知らないライブラリのために利用者側が書くこともできます。いずれの場合も、受け取る側は
それが何を記述しているかを知る必要があるため、オーバーレイがそれを明示し、kenbi は検査できる
ものを検査します:

```c
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 }
// @allocator magick::mem { alloc: AcquireQuantumMemory, free_returns_null: RelinquishMagickMemory }
// @contract qsort { borrows: $1 }
```

- `requires:` はコンパイル行と照合して **検査** されます。これに矛盾するビルドはエラー
  （`CONTRACT_PACKAGE_MISMATCH`）です —— そのコントラクトは別のビルド向けに書かれたもので、
  約束している内容が成り立たない可能性があるからです。コンパイル行で決着しない条件は
  *unverified* として報告され、満たされたとは扱われません。
- `version:` は **宣言されたもの** として引き継がれます。kenbi はライブラリのバージョンをソースから
  読み取れず、読み取れるふりもしません。レポートには「version declared, not verified」と出ます。

`--format=json` はこれらすべて（`versionDeclared`、`requires`、`mismatched`、`unverified`、
`appliesToThisBuild` を持つ `contractPackages`）を含むので、利用者はコントラクト集合に依存する前に
それを信頼するかどうかを判断できます。

### コントラクト集合を公開する

`--emit-contracts` は、解析対象を検査する代わりに、そのコントラクトの *表面* を出力します ——
ライブラリが配布する形式で、別のツール（別のチェッカー、バインディング生成器、他言語の
フロントエンド）がライブラリのコメントを読み直さずに、呼び出し側にライブラリのコントラクトを
守らせられるようにするものです:

```sh
kenbi --emit-contracts --project=build/compile_commands.json > imagemagick.contracts.json
```

```json
{ "kind": "contract-set",
  "packages":  [ { "name": "ImageMagick", "versionDeclared": "7.1.2-27", "appliesToThisBuild": true, … } ],
  "resources": [ { "name": "magick::mem", "alloc": ["AcquireQuantumMemory", …],
                   "free": ["RelinquishMagickMemory", …], "freesFields": ["DestroyKernelInfo", …] } ],
  "contracts": [ { "function": "DestroyKernelInfo", "effect": "@frees", "param": "$1",
                   "declaredBy": "overlay", "implementationSeen": true, "status": "verified" } ] }
```

`resources` は alloc → free の語彙です: deallocator だけを知らされた利用者には、そもそもどの呼び出しが
義務を渡してきたのかが分かりません。また、すべてのコントラクトは、その背後の実装についてこの実行で
確立された `status` を持ちます。「コントラクトが宣言されている」を「実装が検査された」と読めては
ならないからです:

| `status` | 実行で確立されたこと |
|---|---|
| `declared` | ここに実装がない（プロトタイプ、または外部から書かれたコントラクト）—— **何も検証されていない** |
| `unchecked` | 本体はあるが `@kenbi` の下にない: kenbi はそれを検査していない |
| `red` | 本体は `@kenbi` の下にあり、自身のコントラクトに矛盾する —— 依存してはならない |
| `green` | 検査済みでクリーン。ただし信頼に依存している（カバーされていないコントラクト付き callee、または `@unsafe`） |
| `verified` | 検査済みでクリーン。コントラクト付きの閉包全体も同様: 残余なし |

公開は検査ではありません: コードに findings があってもドキュメントは出力され、終了コードは 0 です。
findings は通常の `kenbi` 実行で確認してください。

## 「GREEN」と「verified」は別の答え

注釈は証明ではなく、カバレッジ結果もそのことを示します:

| | 意味 |
|---|---|
| `GREEN (contracted)` | 境界が宣言されている —— 依拠するコントラクトを *前提とすれば* 安全 |
| `verified` | コントラクト付き依存閉包の全体もカバーされている: 信頼に委ねたものがない |
| `trusted frontier` | GREEN が現在依拠している、カバーされていない callee —— これらをカバーすれば閉じる |
| `@unsafe vouches` | kenbi が検査できなかった内容を作者が表明した箇所 |

`verified` は `GREEN` の真部分集合です。カバーされていない callee にコントラクトを宣言すると、関数は
RED から GREEN に移り、その callee は trusted frontier に載ります。実際に finding を抑制している
`@unsafe` は、関数を GREEN のままにしつつ、箇所を明示したうえで恒久的に `verified` から外します。
したがって、kenbi が検証できない操作が、誰かが注釈を付けたという理由で verified と読めることは
決してありません。これらはすべて `--format=json`（`green`、`verified`、`trustedFrontier`、
`unsafeVouches`、およびエントリポイントごとの `flows` とその `blockers`）に含まれます。

```sh
kenbi --compile-commands=build/compile_commands.json src/img.c
kenbi --project=build/compile_commands.json          # the whole project, one closure
kenbi --emit-contracts src/*.c                       # publish the contract set instead
kenbi --format=json src/*.c
kenbi foo.cpp -- -Iinclude -DDEBUG
```

JSON ドキュメントは `{ "version", "tool", "findings": [ { "file", "line",
"code", "severity", "message" } ], "coverage", "scope" }` の形式です。コードは安定しており、順序は
決定論的です。読み取り / パース失敗は `PARSE_ERROR` の finding として現れます。
`scope` は、解析したファイルごとに、どの検査がどの関数で動いたかを示します。`ownership`・`bounds`・`locks`・
`initialisation`・`taggedUnions` のそれぞれについて、`mode` が `file`（すべての関数）、`functions`（一部の関数。
対象外の関数は `unchecked` に名前が入ります）、`off` のいずれかになり、ほかに検査対象外の関数の中で `@kenbi`
が採用したブロックも示します。finding のないファイルは、この範囲の中でだけ問題がないという意味です。テキスト出力では
各ファイルの下に表示します。

## 注釈

リソースはコメントで宣言し、スコープ付きでプロジェクト一意な名前で参照します。
義務（obligation）は変数ではなく *確保*（その「origin」）に属します。コピーはそれを
別名参照し、内部ポインタはそこから派生し、`free` / move が義務を履行します。
分岐は健全に合流します（合流後にある状態が起こりうるのは *いずれかの* パスで
起こりうる場合 —— 片方のパスだけで free すると、もう片方ではリークが残る）。

```c
/* @mem demo::buf { size: n, free: free, owner: p } */
char *p = malloc(n);     // alloc of demo::buf (p is the owner)
char *r = p + 16;        // interior pointer — inferred, must not be freed
consume(p);              // use
sink(p);  // @move demo::buf   — obligation transferred out; p is now moved-from
```

- **確保**: 右辺が `malloc` 系または C++ `new` の初期化 / 代入が、対象変数に義務を束ねる。
- **解放**: `free(p)` または C++ `delete` / `delete[] p`。
- **内部ポインタ**: `p + off` は同じ origin への内部ポインタを派生する。
- **別名**: `q = p` は `q` を `p` の origin の別名にする。
- **copy**: 代入上の `// @copy <resource>` は *ディープ* コピーを表す —— 単なる別名で
  はなく、独自の義務を持つ新たな独立した所有オブジェクト。
- **move**: `// @move` を伴う行の呼び出しは義務を外へ移譲する。
- **unsafe**: 行上の `// @unsafe` はその行を隔離する —— そこの findings は抑制される
  （あなたが責任を負う）。何もカバーしない `@unsafe` は、未使用の lint-disable のように
  `STALE_UNSAFE` として報告される。
- **null 安全**: 宣言上の `// @nullable`（または `@nonnull`）はポインタが null になり
  うるかを表す。nullable なポインタを null チェック（`if (p)`、`if (p != NULL)`、早期
  `return`）なしでデリファレンスすると `NULL_DEREF` —— `Option<T>` の規律で、分岐
  narrowing による flow-sensitive な検査。
- **frees コントラクト**: 関数の上の `// @frees(param)` は、その引数を解放することを
  宣言する。呼び出し側はその呼び出しを解放として扱い（double-free / leak と合成される）、
  関数自身の本体も検査される —— 実際にそのパラメータを解放しなければ
  `CONTRACT_NOT_HONORED`（宣言した意図 vs 実装。注釈のないツールでは検査できない）。
- **must-use 戻り値**: 関数の上の `// @must_use` は、その結果が消費されなければならない
  ことを宣言する。値が捨てられる呼び出し（代入 / return / 受け渡し / 検査されない裸の文）は
  `UNUSED_MUST_USE` —— 無視されたエラーコードやリークした確保に対する `#[must_use]` の規律。

### Goto ボキャブラリ（任意 —— goto の構造化された意図を宣言する）

一般的な前方 goto は自動的にモデル化される（注釈不要）: 前方クリーンアップ ラダー
（`if(!p) goto fail; … fail: free()`）は join-merge で解析され、ループ / switch から
クリーンアップ ラベルへの前方 goto は許容される。*後方* goto ループ、ネストした
ラベルへのジャンプ、計算 goto は拒否されたまま（`UNSTRUCTURED_GOTO`）—— 拒否による
健全性。任意のボキャブラリで goto の構造化された意味を宣言すると、kenbi はそれを
モデル化し、形状を相互検査する:

- ラベル上の `// @goto_noreturn` は非復帰の終端（abort / exit / longjmp）を表す:
  そこに到達するパスは終了するので、まだ所有している義務は履行されたとみなされる ——
  abort パスはリークではない（エラー abort パスでの偽リークを抑制）。
- ラベル上の `// @goto_finally` はクリーンアップ収束ファネルを表す。opt-in の
  single-funnel 規律: リソースをまだ所有したまま、ファネルを *経由せず* に出る exit は
  `FINALLY_BYPASSED`（`goto <funnel>` で解放をそこで行わせる）。収束点での merge の
  完全性は通常の推論解析どおり。
- goto 上の `// @goto_backward` はそれをループ back-edge として宣言する: 単純な goto
  ループは拒否される代わりに do-while に再構成され、有界不動点で解析される
  （イテレーション跨ぎのハザードが捕捉される）。

### 境界（`@spatial`）

関数の上またはファイルレベルの `// @spatial` は、そのスコープで境界の軸を有効にします。バッファを
インデックスする、または `memcpy` などの書き込みサイズを決める信頼できないスカラー引数には、パス上に
境界チェック —— `if` ガード、ループ条件、`% n`、クランプ、マスク —— が存在しなければならず、
なければ `UNVALIDATED_INDEX` / `UNVALIDATED_SIZE` です。チェックはバッファをカバーしなければならず
（存在しても緩すぎれば `INAPPROPRIATE_BOUND`）、符号付きインデックスには `i >= 0` も必要で
（`INDEX_MAYBE_NEGATIVE`）、ガードの算術はラップしてはなりません: 符号なしの `i` に対する
`i + 4 <= n` は認められず、`n >= 4 && i <= n - 4` は認められます。kenbi はパス上のチェックを
探すのであって、チェックを取り除くことはありません。

- 関数の上の `// @counted_by(<buf>: <len>)` はポインタ引数にサイズを与えます。フィールド
  （`b->buf: b->cap`）やリングバッファのマスク（`b->mask + 1`）としても指定できます。
- `// @invariant(<field> <rel> <size>)` はデータ構造の不変条件を宣言します（例:
  `parser->toknext <= num_tokens`）。そのフィールドは保護され、それへの書き込みはすべて
  `// @maintains(...)` を必要とし、kenbi がそれを検証します（`UNGUARDED_INVARIANT_WRITE`、
  `INVARIANT_NOT_MAINTAINED`）。そのフィールドで抑えられたインデックスは、この関係を通じてカバーされます。

### 初期化（`@initcheck`）とタグ付き共用体（`@typecheck`）

- 関数の上またはファイルレベルの `// @initcheck`: 初期化子なしで宣言されたスカラーまたはポインタの
  ローカル変数は、読まれる前にすべてのパスで代入されなければならず、そうでなければ `USE_OF_UNINITIALIZED`。
- `// @typecheck` と、共用体メンバごとの `// @variant(<member>: <tag> == <value>)`: タグが証明されて
  いない（`if (n->tag == 1)`、またはタグに対する `case 1:`）パス上でメンバを使うと `TYPE_CONFUSION`。

### C++

`// @raii`（または `// @raii(Name)`）は、デストラクタが所有物を解放するクラスを示し、kenbi は
デストラクタが実際に解放することを検査します。独自のコピー操作を持たないそのようなクラスをコピーすると
`MISSING_COPY_CONTROL`、コピー元を読む前に解放する `operator=` は `SELF_ASSIGN_UNSAFE` です。
派生クラスのオブジェクトを、仮想デストラクタを持たない基底クラス経由で `delete` すると `DELETE_NONVIRTUAL_BASE` です。
`std::unique_ptr` / `std::shared_ptr`、`std::move`、`.get()` / `.release()` / `.reset()`、
ラムダ、例外パス（`LEAK_ON_THROW`、`try` / `catch`、`noexcept` / `// @nothrow`）がモデル化されます。
完全なリファレンスは MCP サーバが `kenbi://annotations` として提供しています
（[ソース](mcp/src/annotations.ts)）。

### 並行性注釈（`@threadsafe` の下では検証、その外では advisory）

`@threadsafe` スコープ（関数またはファイル）では、これらはロック保持 typestate パスによって
default-red で **検証** されます:

- `// @guarded_by(<field>: <lock>)`（関数に付ける）または `// @guarded_by(<lock>)`（構造体メンバに
  付ける）: ロックの保持が証明されないアクセスは `UNGUARDED_ACCESS`。ガードされたフィールドの
  アドレスを取ると `GUARDED_ESCAPE`。
- ロックの釣り合い: `LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK`。
- `// @acquires(<lock>)` / `// @releases(<lock>)`: 本体で検証され（`LOCK_NOT_ACQUIRED`）、
  呼び出し箇所で消費される。callee 上の `// @requires_lock(<lock>)`: `REQUIRED_LOCK_NOT_HELD`。
- `// @lock_order(<a> < <b>)`: `LOCK_ORDER_VIOLATION`（AB-BA デッドロック —— Rust が与えない保証）。
  矛盾する宣言は `LOCK_ORDER_CONFLICT`。`// @lock_class(<X>)` はロックの同一性に名前を付け、
  関数やファイルをまたいで順序とコントラクトを対応させる。同じクラスの 2 つのインスタンスには
  正準順序が必要（`SAME_CLASS_NO_ORDER`）。
- 関数ポインタ上の `// @calls(<fn>, ...)`: その宣言された呼び出し先。ロック下での未宣言の間接呼び出しは
  `UNDECLARED_INDIRECT_CALL`、集合外の代入は `UNDECLARED_FN_TARGET`。

`@threadsafe` スコープの外では、kenbi はこれらをパースして `severity: "advisory"`
（`GUARDED_BY`、`REQUIRES_LOCK`、`ACQUIRES`、`RELEASES`、`LOCK_ORDER`）で出力します。
**advisory な findings は決してビルドをゲートしません** —— それらは AI / 人間レビュアー向けの
ディレクティブです。`// @llm <freeform>` → `LLM_REVIEW` は、レビュアーに何を確認すべきか伝える
自由記述の指示です。

### mini-format（エンジン用フィクスチャ）

```
@mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
alloc <var> <resource> | copy <dst> <src> | interior <dst> <src> <off>
use <var> | free <var> | move <var> | if / else / endif
```

## 現在の検出項目

決定論的（`error` / `warning`）: `DOUBLE_FREE`、`USE_AFTER_FREE`、
`USE_AFTER_MOVE`、`LEAK`、`FREE_INTERIOR`、`MOVE_INTERIOR`、`FREE_AFTER_MOVE`、
`MOVE_AFTER_FREE`、`DOUBLE_MOVE`、`WRONG_DEALLOCATOR`、`NULL_DEREF`（null かもしれない
ポインタのもの、および —— 別に区別して —— kenbi が null だと分かっているポインタのもの:
`free(p); p = NULL; *p`、または NULL を返すと宣言された解放の後の読み出し）、
`CONTRACT_NOT_HONORED`、`UNUSED_MUST_USE`、`DANGLING_RETURN`（ローカルへのポインタ /
解放済みポインタの return）、`BORROW_FREED`（`@borrows` / arena オブジェクトを個別に
解放）、`BORROW_OUTLIVES_OWNER`（owner / arena が消えた後の使用）、
`UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE`（所有ポインタが、所有権コントラクトを
宣言しない callee / release 境界を越える —— default-red の規律）、
`UNSTRUCTURED_GOTO`（kenbi がモデル化を拒否する後方 / ネスト / 計算 goto）、
`LOOP_FIXPOINT_LIMIT`（解析が反復上限内で収束しないループ。不完全な見え方から判定せず拒否する）、
`LEAK_ON_THROW`（C++: nothrow 保証のない callee —— または素の `new` —— が巻き戻しうる箇所で
生の owner がまだ保持されている。RAII owner は対象外で、`noexcept` / `@nothrow` /
`-fno-exceptions` が証明となる。`try` 内では巻き戻しによる exit はハンドラに着地し、
ハンドラはその合流点から検査される）、
`FINALLY_BYPASSED`（所有したまま出る exit が、宣言された `@goto_finally` ファネルを迂回する）、
`FREE_NONHEAP`（スタックなどヒープ以外の記憶域を指すポインタの `free`）、`BORROW_MOVED` /
`UNCONTRACTED_MOVE`（借用からの move、または受け取りを宣言しない callee への move）、
`REALLOC_UNVERIFIED` / `REALLOC_SELF_REASSIGN`（結果が使用前に確定しない `realloc`、または唯一の
ハンドルが上書きされる `realloc`）、`MISSING_COPY_CONTROL` / `SELF_ASSIGN_UNSAFE` / `DELETE_NONVIRTUAL_BASE`（C++）、
`UNSUPPORTED_CONSTRUCT`（kenbi がモデル化しない構文内の確保や解放。捨てずに拒否する）、
加えて `UNKNOWN_RESOURCE` / `STALE_UNSAFE` の衛生チェック。opt-in の軸の下では:
`UNVALIDATED_INDEX`、`UNVALIDATED_SIZE`、`INAPPROPRIATE_BOUND`、`INDEX_MAYBE_NEGATIVE`、
`UNGUARDED_INVARIANT_WRITE`、`INVARIANT_NOT_MAINTAINED`（`@spatial`）、`USE_OF_UNINITIALIZED`
（`@initcheck`）、`TYPE_CONFUSION`（`@typecheck`）、そして `UNGUARDED_ACCESS`、`GUARDED_ESCAPE`、
`LOCK_LEAKED`、`DOUBLE_LOCK`、`UNLOCK_WITHOUT_LOCK`、`LOCK_NOT_ACQUIRED`、
`REQUIRED_LOCK_NOT_HELD`、`LOCK_ORDER_VIOLATION`、`SAME_CLASS_NO_ORDER`、
`UNDECLARED_INDIRECT_CALL`、`UNDECLARED_FN_TARGET`（`@threadsafe`）。ループ
（`for`/`while`/`do` および宣言された goto ループ）は収束まで **有界不動点** で
解析されるので、イテレーション跨ぎのハザードが捕捉されます。`break`/`continue` と前方
goto クリーンアップ ラダーがモデル化され、リークは関数のすべての exit で検査されます。

Advisory（`advisory` severity、決してゲートしない —— レビュー層向け）: `GUARDED_BY`、
`REQUIRES_LOCK`、`ACQUIRES`、`RELEASES`、`LOCK_ORDER`、`LOCK_ORDER_CONFLICT`、
`LLM_REVIEW`、`ESCAPE_UNCHECKED`（kenbi が追跡しないフィールドへ所有権が格納された ——
境界は黙って捨てられず表面化される）、`POSSIBLE_DOUBLE_FREE` /
`POSSIBLE_USE_AFTER_FREE`（可視の本体が引数を解放する、コントラクトのない callee ——
`@frees` が宣言されて確定するまでのヒント）、`CONTRACT_UNBOUND`（シグネチャにない引数を
名指しするコントラクト）、`UNKNOWN_VAR`（その時点でハンドルに対する origin を kenbi が
記録していないため、そこでは何も検査されない —— kenbi 自身の記録に対するトリップワイヤであり、
コードについての主張ではない）。

## 実証: Rust では `unsafe` → kenbi では `@unsafe` なしで検証済み

双方向参照（`prev` *かつ* `next`）を持つ双方向連結リストは、安全な Rust では `unsafe`
な生ポインタを必要とします（または *実行時* にチェックされる `Rc<RefCell<…>>`/`Weak`）:
借用チェッカーはリンクの共有された循環所有権を表現できません —— std の `LinkedList`
自体が `unsafe` で構築されています。

同じ構造は kenbi の `@arena` 規律（[`demo/dll.c`](demo/dll.c)）の下で
**`@unsafe` なしでメモリ安全と検証されます**:

```
$ kenbi demo/dll.c
demo/dll.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

すべてのノードは arena に存在し、循環する `prev`/`next` ポインタは arena の寿命を
共有し、個別に解放されるノードはなく、領域が破棄された後に使われるものもありません ——
すべて静的に、すべてのパスで検査されます。安全な Rust が循環参照を *表現する* ために
`unsafe` を強いるところで、kenbi は宣言された検査済みの規律の下でそれらを *検証します*。

**正直なスコープ。** これは *宣言された* `@arena` 規律の下でのメモリ安全性
（use-after-free / double-free / leak / use-after-region-free / 個別解放なし）であり、
Rust の完全な保証 **ではありません**: aliasing-XOR-mutation（`&mut`）やデータレースからの
自由は強制せず、arena は単純さと引き換えにメモリ（領域全体が一度に解放される）を払います。
主張は狭く、そして本物です: kenbi は、単一モデルの言語が `unsafe` に落ちざるを得ない
このパターンを静的に検査可能にする *規律をホストできます*（領域所有権）。対比として
[`demo/vec.c`](demo/vec.c)（`Vec<i32>` 相当）: 構造体フィールドに格納された手動 `malloc`
はクリーンに検証されますが `ESCAPE_UNCHECKED` の **advisory** を上げます —— フィールドの
所有権は黙って通されるのではなく、正直に未検査として示されます。

## 1 つのアロケータ、複数の型付きデストラクタ

実際のプロジェクトは汎用ラッパーで確保し、その周りの型付きデストラクタを通じて解放します。
そのため `free:` / `free_returns_null:` は複数の解放名を受け付け —— すべてがそのファミリーの
正当な解放であり、それ以外は引き続き `WRONG_DEALLOCATOR` です —— `frees_fields:` は、そのような
デストラクタがオブジェクトの所有フィールドも解放することを記録します:

```c
// @allocator magick::mem { alloc: AcquireQuantumMemory AcquireKernelInfo …,
//                          free_returns_null: RelinquishMagickMemory DestroyKernelInfo …,
//                          frees_fields: DestroyKernelInfo … }
```

フィールドがまだ所有している状態でコンテナを解放するのは、デフォルトでは `LEAK` です —— 素の
`free(s)` に対しては正しく、グラフを解放するために存在するデストラクタに対しては誤りです。そのため
それを許可するのは宣言であり、宣言されていない解放は RED のままです。

ImageMagick でこれらの対を宣言すると件数は増えます（95 ファイル全体で 689 → 729）。これは
リグレッションではなく閉包が外側へ広がった結果です: `DestroyKernelInfo(kernel)` の呼び出しは以前は
コントラクトのない境界でした —— kenbi はそこで解放が起きたことを見られず、そこを通るものは何も
検査されませんでした —— それが今は kenbi が検査する解放になり、今度はそのオブジェクトを誰が
所有しているのかを問うようになります。実際のリークも 1 件見つかりました: `OrderedDitherImage`
（threshold.c）は `SetImageStorageClass` の失敗時に、他のすべての exit が行っている
`DestroyThresholdMap` を行わずに return します。

*2026年9月に、ImageMagick 7.1.2-27 と当時の kenbi で測定した値です。その後の kenbi では件数が異なります。*

## 編集できないコードにコントラクトを付ける

ここまでのコントラクトはすべて宣言の上に置く必要があります —— しかしサードパーティのプロジェクトには
それを置く場所がありません。`@contract` は代わりに関数を名指しするので、語彙全体を、強制インクルード
されるコメントだけのオーバーレイヘッダから使えます:

```c
// @contract qsort            { borrows: $1 }
// @contract DestroyKernelInfo { frees: $1 }
// @contract AddValueToSplayTree { borrows: $1, moves: $2 $3 }
```

引数は名前に加えて位置（`$1`、1 始まり）でも指定でき、たいていはこれが必要になります: C のヘッダは
引数を無名で宣言することが多く、コントラクトを必要とする呼び出し箇所にはプロトタイプしか見えないからです。

これは同じコントラクトが同じ束縛を通じて解決されたものです —— したがって **信頼されるのではなく
検査されます**。本体が翻訳単位内にある関数への `frees:` 宣言はその本体と照合され（解放しなければ
`CONTRACT_NOT_HONORED`）、宣言された `borrows:` 引数を解放すると `BORROW_FREED` です。また借用を
宣言すると呼び出し側に解放の義務が残るので、渡されたまま解放されないポインタは、判定不能な境界ではなく
目に見える `LEAK` になります。シグネチャにない引数を名指しするコントラクトは何も束縛しません ——
境界は安全側である RED のままで、理由を示す `CONTRACT_UNBOUND` の advisory が出ます。

ImageMagick の MagickCore（95 ファイル、プロジェクト本来のコンパイル行）では、
[`demo/imagemagick/kenbi_magick_api.h`](demo/imagemagick/kenbi_magick_api.h) の 10 個の `borrows`
宣言で findings が 657 から 626 に、`UNCONTRACTED_ESCAPE` が 249 から 216 に減り —— 新たに 2 件の
`LEAK` が表面化します。これは仕組みが働いている証拠です: 宣言された境界は判定可能な境界です。
*ファクトリ* には `@allocator` を推奨します —— ファミリーの `alloc:` リストに名前を加えると、リソースと
その deallocator も名指しされるので、リークと `WRONG_DEALLOCATOR` も検査されます（それだけで
xml-tree.c のコントラクトのない解放 26 件のうち 16 件が解消しました）。

*2026年9月に、ImageMagick 7.1.2-27 と当時の kenbi で測定した値です。その後の kenbi では件数が異なります。*

## 侵入型リスト: リンクを宣言し、ドレインを宣言する

もう 1 つの C のリスト —— ノードがヒープ上にあり、フィールドで連鎖し、1 つずつ解放される —— は
arena ではなく、kenbi の確保箇所単位のリソースモデルが表に出るところです。すべてのノードは 1 つの
`malloc` から来るので、プログラムにはオブジェクトの連鎖があるのに kenbi には 1 つのリソースしか
見えていませんでした: 走査中の解放は「その」リソースの解放と読まれ、次のステップは解放後の使用と
読まれていました。

2 つの宣言で連鎖が検査可能になり、どちらも信頼に委ねられることはありません:

```c
/* @mem t::n { free: free, owner: cur, link: next } */   /* per resource… */
// @list Cluster { link: next }                           /* …or per record TYPE */

/* @drains(head) */
for (cur = head; cur != NULL; cur = nxt) { nxt = cur->next; free(cur); }
```

`link:` は、そのリソースがそのフィールドで連鎖したコレクションの NODE であることを示すので、走査は
kenbi が位置づけられないポインタではなく別の要素となり、走査中の解放は ELEMENT を取り除くことになります。
`@drains(head)` は 1 つのループがすべての要素を解放することを示します —— そして kenbi はそれを検査します:
何も解放しないループは `CONTRACT_NOT_HONORED`、何もドレインしないコレクションは `LEAK`、
`free(cur); cur = cur->next;` は `USE_AFTER_FREE`、進める前にカーソルを 2 回解放すると
`DOUBLE_FREE` で、コレクションがドレインされた後はすべてのカーソルがダングリングになります。

[`demo/list.c`](demo/list.c) はこれを 30 行にまとめたもの —— 構築、走査、ドレイン —— で、
クリーンに検証されます:

```
$ kenbi demo/list.c
demo/list.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

TYPE 形式は kenbi が編集できないコードにも届きます。ImageMagick のクラスタリストは
`MagickCore/segment.c` の 9 つの関数で走査されます。強制インクルードされるオーバーレイ
（[`demo/imagemagick/kenbi_magick_lists.h`](demo/imagemagick/kenbi_magick_lists.h)）のコメントだけの
1 行で、このファイルの findings は 83 から 14 になり、54 件の `USE_AFTER_FREE` と 4 件の
`DOUBLE_FREE` はすべて消えます。ヘッダに書けないのは、どのループがリストをドレインするかです ——
それは文についての事実だからです —— そのため、それらのコレクションはループでドレインが宣言されるまで
RED のままです。それこそ kenbi が問うべき問いであり、ファイルの外から答えられる問いではありません。

*2026年9月に、ImageMagick 7.1.2-27 と当時の kenbi で測定した値です。その後の kenbi では件数が異なります。*

## 設定による低レベル検証（`--safety`）

低レベルコードの性質の中には、そもそもソースに現れないものがあります: どの関数が割り込みで走るか、
デバイス API に何が許されるか、ビルドがどれだけのスタックを使うか、DMA エンジンがどのメモリに
届くか。`--safety=project.json` はそれらをプロジェクトファイルと契約ファイルから受け取り、
ソースをそれらと照合して検査します:

```sh
kenbi --format=json --safety=demo/safety/project.json
```

| 性質 | ドキュメント |
|---|---|
| 呼び出し閉包内の禁止された効果（割り当て、ブロッキング、待機、再帰）、ブロック単位または関数単位 | [効果](docs/configured_effects.md)、[再帰](docs/configured_recursion.md)、[状態ごとの効果](docs/configured_state_effects.md) |
| リソースの状態機械（操作順序、終了状態、戻り値ごとの結果） | [プロトコル](docs/configured_protocols.md)、[結果](docs/configured_protocol_results.md)、[ブロック](docs/configured_protocol_blocks.md)、[関数境界](docs/configured_function_boundaries.md) |
| 非同期操作に借用されたバッファ（完了前の変更・解放・再利用の禁止） | [非同期借用](docs/configured_async_borrows.md)、[容量](docs/configured_borrow_capacity.md)、[整列](docs/configured_borrow_alignment.md)、[バッファマーク](docs/configured_buffer_marks.md)、[読み出し専用記憶域](docs/configured_storage_permissions.md) |
| 実行文脈（割り込み、スレッド）とそれぞれが許す API | [文脈](docs/configured_contexts.md) |
| 読み出し・書き込み・API アクセスの範囲と整列 | [ソースのアクセス](docs/configured_source_access.md)、[API の容量](docs/configured_access_capacity.md)、[API の整列](docs/configured_access_alignment.md)、[返されるポインタ](docs/configured_return_pointer.md)、[ポインタの再代入](docs/configured_pointer_bindings.md) |
| 順序検査におけるループとカウンタ | [for](docs/configured_for_loops.md)、[do-while](docs/configured_do_while.md)、[符号なし更新](docs/configured_unsigned_updates.md)、[整数引数](docs/configured_integer_parameters.md) |
| 確保契約、プールとヒープの上限、メモリ領域 | [確保](docs/configured_allocation.md)、[メモリ領域](docs/configured_memory_regions.md) |
| 呼び出し深さとスタック使用量（コンパイラの `-fstack-usage` 出力から） | [呼び出し深さ](docs/configured_call_depth.md)、[スタック使用量](docs/configured_stack_usage.md) |
| MMIO レジスタマップ（読み出し専用 / 書き込み専用、write-1-to-clear、読み出しクリア、予約ビット、アクセス幅、必要なバリア） | [MMIO](docs/configured_mmio.md) |
| 外部の WCET ツールが与える実行時間の上限（ビルドに結び付けたもの） | [実行時間](docs/configured_execution_time.md) |
| 契約ファイルを、それが書かれた対象のソース・コンパイルオプション・ターゲットに結び付ける | [適用先ファイル](docs/configured_contract_artifacts.md)、[コンパイル条件](docs/configured_contract_compilation.md)、[ターゲット](docs/configured_contract_target.md) |

すべての義務は `verified`、`conditional`（外部契約の下で成り立つもので、結果はそれらを前提として
列挙します）、`unverified`、`violation` のいずれかとして報告されます。kenbi が解決できないものは
すべて `unverified` で、実行が合格するのは、すべての義務が `verified` であるか、プロジェクトファイルが
明示的に受け入れた前提の下で `conditional` である場合だけです。上記の各ドキュメントには、それぞれが
対象外とする範囲が記載されています。
[`demo/safety/`](demo/safety/) と [`demo/dma/`](demo/dma/) は架空のデバイスを題材にした実例です。

## GREEN が約束すること・しないこと

GREEN が意味するのは、実行された検査の範囲内で、kenbi が解析したコードについて、すべてのパスが
宣言されたコントラクトに適合しているということです。次のことは意味しません:

- **有効にした軸を超えた安全性。** `@spatial` のないファイルでは境界は何も検査されていません。
  `@kenbi` がファイルの一部を示している場合、残りの部分は何も検査されていません。
- **コントラクトを超えた安全性。** kenbi が見ていないコードへのコントラクトは信頼されたもので、
  trusted frontier として列挙されます。`@unsafe` は作者の言明であり、これも列挙されます。
  `verified` は、何も信頼に委ねていない答えです。
- **ビルドが定義するものを超えた安全性。** プリプロセッサで除外されたコード、別の
  `compile_commands.json`、別のターゲットは解析されていません。

kenbi はモデル化できないものをスキップせずに拒否します: `UNSTRUCTURED_GOTO`（後方 goto、ネストした
ラベルへのジャンプ、計算 goto）、`LOOP_FIXPOINT_LIMIT`、`UNSUPPORTED_CONSTRUCT`、そして `--safety`
の下での `unverified`。大規模な実コードでは、これらの拒否も結果の一部です —— それを含む関数は、
再構成されるか宣言されるまで RED のままです。

GREEN であるべきでない GREEN を見つけたら、最小の再現例を添えて報告してください: それは kenbi が
抱えうる最も深刻な種類のバグです。

## アーキテクチャ

解析エンジンはフロントエンドから分離しています。エンジンはフロントエンドに依存しない IR の上で動くので、
C/C++ のパースは差し替え可能な部品です。

```
*.c / *.cpp  ──▶ libclang front-end  ┐
                 (src/frontend_c.nim) ├─▶ Program IR ─▶ typestate engine ─▶ diagnostics
*.mc         ──▶ mini-format parser  ┘   (src/ir.nim)   (src/analyze.nim)
                 (src/parse.nim)
```

| ファイル | 役割 |
|---|---|
| `src/ir.nim` | フロントエンド非依存の IR（`Program`: リソース + 文の木） |
| `src/analyze.nim` | typestate エンジン（origin、may-set 合流、ループ不動点、リーク走査、カバレッジ） |
| `src/clang.nim` | 最小 libclang FFI（by-value 構造体は C ABI に一致） |
| `src/frontend_c.nim`、`src/cfront_*.nim` | 実際の C/C++ と注釈コメントを `Program` へ lowering |
| `src/annotations/` | 注釈語彙のレジストリ |
| `src/compile_db.nim` | `compile_commands.json` からパースフラグを抽出 |
| `src/safety_config.nim`、`src/safety_check.nim` | `--safety`: プロジェクトファイルと契約ファイル、設定による検査 |
| `src/effect_facts.nim`、`src/protocol_*.nim` | `--safety`: 呼び出し閉包の効果、状態機械、借用 |
| `src/parse.nim` | mini-format パーサ（エンジン用フィクスチャ） |
| `src/kenbi.nim` | CLI: 拡張子で振り分け、診断を出力 |

## テスト

`tests/*.mc` はエンジンを直接駆動します（17 ケース）。`tests/c/*.c` と `tests/cpp/*.cpp` は、
それらのシナリオに加えて注釈固有のチェックを実際の C / C++ で書いたものです（349 ケース）。ランナーは
各ファイルを libclang で lowering し、生成された診断を —— **その発生行も含めて** —— 各ファイルの
`//EXPECT CODE` マーカー（その行自体に書くか、`//EXPECT CODE@LINE`）と突き合わせて検証します。
行が違っても、診断の過不足があっても suite は失敗します。`tests/run_tests_project.nim` は
プロジェクト横断のカバレッジ結果を、`tests/run_tests_*.py` の各 suite は `--safety` をエンドツーエンドで、
`demo/verify_three_state.py` は [三段階コーパス](demo/README_three_state.md) とそこから生成される
MCP サーバの資料を検査します。

## ライセンス

kenbi は Apache License 2.0 で提供しています（[LICENSE.md](LICENSE.md)）。他のプロジェクトに由来する素材と
そのライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) に記録しています。
