# kenbi

[English](README.md) · **简体中文** · [日本語](README.ja.md) · [Español](README.es.md) · [Português](README.pt.md) · [Français](README.fr.md) · [Deutsch](README.de.md)

**kenbi 检查 C/C++ 代码是否遵守它所声明的内存安全规则。** 你在代码旁用注释写明谁拥有缓冲区、谁释放它、借用持续多久；kenbi 静态地、在每条路径上检查代码是否符合这些注释。它不是编译器，也不改变你的构建。

**为与 AI agent 一起编写 C/C++ 而设计。** 通过它的 [MCP 服务器](#与-ai-编程-agent-一起使用-mcp)，agent 检查自己刚写的 C/C++，询问某个结果为何出现、修复应是什么样子，并反复进行，直到检查不再报告任何问题。内存安全由此成为 agent 编写循环的一部分，而不是事后的审查；agent 写下的注解留在代码中，作为 kenbi 持续检查的规则。

> 状态：**v0.1.0**，早期开发阶段。接口、注解词汇以及 JSON 输出仍可能变化。

## 初次一览

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

`@kenbi` 让该文件接受所有权检查，`@mem` 声明一种资源及其分配与释放方式。把提前返回改为 `{ free(p); return NULL; }`，文件就会报告 `ok — no findings from the checks that ran`，退出码为 0。`checked:` 行出现在每个结果中：没有结果只针对它所列出的检查。

## 有何不同

- **声明而非推断。** kenbi 不猜测代码的含义，而是对照注解所声明的内容来检查代码，因此一条结果是代码偏离既定规则之处，而不是看起来可疑的模式。
- **未证明的不会是 GREEN。** 凡是 kenbi 无法证明每条路径都遵守规则的地方，它都会报告；它无法建模的结构（例如向后的 `goto`）也会报告，而不是跳过。没有结果的结论，是 kenbi 为之负责的结论。
- **不运行代码，覆盖每条路径。** sanitizer 和测试只看到实际运行的路径；kenbi 沿着循环、提前返回、`goto` 清理链和 C++ 异常走遍每条路径。
- **确定性，并说明范围。** 相同输入得到相同输出，每个结果都列出运行了哪些检查、依赖哪些契约，以及每个压制了结果的 `@unsafe`。
- **可逐步采用。** 每项检查都单独启用，可按文件、函数或代码块进行，现有代码不会变成一片红。

## 与 AI 编程 agent 一起使用 (MCP)

[MCP 服务器](mcp/README.md) 为 agent 提供检查器以及据此行动的材料：

| | agent 得到什么 |
|---|---|
| `check_memory_safety` | kenbi 的结果，以及说明对哪些函数运行了哪些检查的摘要，因此“没有结果”不会被读成“安全” |
| `explain_finding` | 对于一个结果代码或 CWE 编号：触发原因、为什么半吊子的修复仍然失败，以及连同所声明契约的修复 |
| `kenbi://annotations` | 注解参考 |
| `kenbi://patterns` | kenbi 接受的安全 C/C++ 写法，与它拒绝的不安全写法并列 |

循环是 编写 → 检查 → 解释 → 修复 → 再检查，何时结束由 kenbi 而不是模型决定。服务器还会告诉 agent 不要在注释中重复注解已经说明的内容：注解会被检查，注释不会。

在 [`demo/quickstart.c`](demo/quickstart.c) 上的循环，以及服务器的实际回复（每个摘要之后都跟着 kenbi 的完整 JSON 文档，这里省略）：

1. agent 编写 `dup_name` 并调用 `check_memory_safety`：

   ```text
   kenbi: 1 error(s), 0 warning(s) across 1 file(s):
     demo/quickstart.c:8: error: leak: 'app::buf' allocated here is never freed or moved [LEAK]

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 0 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

2. 它以 `LEAK` 调用 `explain_finding`，得到示例；第一个示例以修复结尾：

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

3. 它在提前返回时释放 `p`（`if (p[0] == '\0') { free(p); return NULL; }`），然后再次检查：

   ```text
   kenbi: no findings in 1 file(s) from the checks that ran. This is not a statement about anything outside the scope below.

   Scope — the result covers only this:
     - ownership, lifetime and null (`@kenbi`, or a file with no marker): checked in every function
     - NOT checked anywhere: bounds (`@spatial`); locks (`@threadsafe`); initialisation (`@initcheck`); tagged unions (`@typecheck`)
     - verified (nothing taken on trust): 1 of 1 adopted memory-relevant functions
     - code the preprocessor excluded under these flags was not analysed
   ```

[`integrations/agent/`](integrations/agent/) 为 Claude Code（`SKILL.md`）、Codex 类 agent（`AGENTS.md`）和 GitHub Copilot 提供了相应的说明。

配置方法见 [`mcp/README.md`](mcp/README.md#configure-in-an-mcp-client)。

## 检查内容

每项检查都单独启用：

| 轴 | 选择加入方式 | 检查内容 |
|---|---|---|
| 所有权 / 生命周期 | `@kenbi`（或不带任何标记的文件） | use-after-free、double free、每个出口处的泄漏、use-after-move、错误的 deallocator、悬垂返回、借用与 arena 生命周期、声明契约 vs 函数体、C++ RAII 所有者、智能指针以及异常路径 |
| null | 始终启用，配合 `@nullable` / `@nonnull` | 对可能为 null 或已知为 null 的指针的解引用，流敏感并带收窄 |
| 边界 | `@spatial` | 到达缓冲区的不可信索引或大小，需要一个存在的、充分的、不会溢出的边界检查；`@counted_by` 以及声明的数据结构不变式（`@invariant` / `@maintains`） |
| 初始化 | `@initcheck` | 局部变量在尚未于每条路径上都被赋值之前就被读取 |
| 带标签联合体 | `@typecheck` + `@variant` | 在其标签未被证明的位置使用联合体成员 |
| 锁 | `@threadsafe` | 未受保护的访问、不平衡的加锁、声明的加锁顺序（AB-BA 死锁） |
| 底层性质 | `--safety=project.json` | 调用闭包中被禁止的效应、资源状态机、栈与调用深度、内存区域、MMIO 等——见[配置驱动的底层验证](#配置驱动的底层验证--safety) |

libclang 前端将真实的 C / C++（读取 `compile_commands.json`）下降（lowering）到 typestate
引擎。循环被分析到有界不动点；前向 `goto` 清理阶梯、`break` / `continue` 以及 `try` / `catch`
都被建模；kenbi 无法建模的内容会被报告，而不是被跳过。输出为文本或 `--format=json`。

## 快速开始

```sh
# Debian / Ubuntu; for other systems see "各操作系统安装 libclang" below.
# Nim 2.2 or later: https://nim-lang.org/install.html
sudo apt-get install libclang1-14 libclang-common-14-dev
git clone https://github.com/puffball1567/kenbi
cd kenbi
nimble build -d:release
./kenbi demo/quickstart.c
```

## 依赖要求

- **Nim** >= 2.2（[安装方法](https://nim-lang.org/install.html)）
- **libclang**（共享库；*不需要* `clang-c` 头文件 —— 仅需运行时的
  `.so` / `.dylib` / `.dll`，在启动时动态加载）。
- **clang 的内置头文件**（`stddef.h`、`stdarg.h` 等），libclang 解析包含它们的文件时需要。
  大多数 clang/LLVM 软件包会随库一起提供；在 Debian 和 Ubuntu 上它们是单独的软件包
  `libclang-common-N-dev`。

libclang 在运行时按 soname 加载；默认搜索列表覆盖 `libclang.so`、
`libclang-13..18.so` 等。若你的库名称或路径不同，可在编译时覆盖：

```sh
nim c -d:kenbiLibclang=/full/path/to/libclang.so -o:kenbi src/kenbi.nim
```

## 构建与测试

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

### 各操作系统安装 libclang

**Ubuntu / Debian**
```sh
sudo apt-get install libclang1-14 libclang-common-14-dev
# libclang1-14 is the library (/usr/lib/x86_64-linux-gnu/libclang-14.so.1, found by default);
# libclang-common-14-dev holds clang's builtin headers (stddef.h, stdarg.h, ...). Without
# them every file that includes one fails to parse, and kenbi reports it unanalysed (exit 2).
# If unresolved, point at it explicitly:
nim c -d:kenbiLibclang=/usr/lib/llvm-14/lib/libclang.so -o:kenbi src/kenbi.nim
```

**Fedora / RHEL**
```sh
sudo dnf install clang-libs               # provides /usr/lib64/libclang.so.*
```

**Arch**
```sh
sudo pacman -S clang                      # /usr/lib/libclang.so
```

**macOS**（Homebrew 的 LLVM，或 Xcode Command Line Tools）
```sh
brew install llvm
nim c -d:kenbiLibclang="$(brew --prefix llvm)/lib/libclang.dylib" \
      -o:kenbi src/kenbi.nim
# Apple's Command Line Tools also ship a libclang at
#   /Library/Developer/CommandLineTools/usr/lib/libclang.dylib
```

**Windows**（MSVC + LLVM 发行版）
```bat
:: install LLVM from https://releases.llvm.org and ensure libclang.dll is on PATH
nim c -d:kenbiLibclang=libclang.dll -o:kenbi.exe src\kenbi.nim
```

## 用法

```
kenbi [--format=text|json] [--compile-commands=PATH] [--project[=PATH]] [--emit-contracts]
      <file> [more...] [-- <extra clang args>]
kenbi [--format=text|json] --safety=project.json
kenbi --version
```

- `kenbi --version` 输出 kenbi 的版本以及所加载的 libclang。
- `*.c *.cc *.cpp *.cxx` → libclang 前端（按扩展名判定 C 或 C++）。
- `*.mc` → 迷你格式。
- 对 C/C++，解析标志来自 `compile_commands.json`：用 `--compile-commands=PATH`
  传入，或从源文件向上逐级目录自动查找。`--` 之后的所有内容都会追加到 clang 命令行。
- `--project[=compile_commands.json]` 分析数据库列出的每一个翻译单元。每个文件的结果
  仍只属于它自己（注解以文件为作用域，分析也是如此）—— 它所增加的是**闭包**：对一个定义在
  另一个被分析单元中的函数的契约化调用，会解析为该单元的判定结果，因此一个其整个依赖闭包
  都已被分析且均为 GREEN 的 GREEN 算作 *verified*，而可信前沿（trusted frontier）收窄为
  项目中没有任何部分定义的东西（以二进制形式提供的库、操作系统、FFI 边界）。不带路径时，
  从给出的第一个文件向上逐级目录查找数据库。
- `--format=json` 输出带稳定代码的机器可读结果（用于 CI、编辑器和 agent）；
  `--format=text`（默认）则是人类可读的。
- `--safety=project.json` 运行[配置驱动的底层验证](#配置驱动的底层验证--safety)中所述的
  配置驱动的底层检查。
- 退出码：`0` 干净 · `1` 发现问题 · `2` 用法 / 解析错误。


## 选择加入：文件、函数或代码块

`@kenbi` 标记处于纪律之下的范围 —— 其外的结果会被丢弃，因此可以逐步采用，绝不会出现
满屏红色。该标记绑定到它所在位置下方的对象：

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

处于纪律之下的代码块**不会**把它所在的函数也纳入纪律：这样的代码块会被单独计数，并在
单独一行（`blocks adopted`）中报告，绝不会并入已采用函数的计数。

## 为库提供契约

契约覆盖层（overlay）是一个由注释组成的文件 —— 它可以随库一起发布，也可以由使用方为一个
从未听说过 kenbi 的库编写。无论哪种情况，接收方都必须知道它描述的是什么，因此覆盖层会
写明这一点，而 kenbi 检查它能检查的部分：

```c
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 }
// @allocator magick::mem { alloc: AcquireQuantumMemory, free_returns_null: RelinquishMagickMemory }
// @contract qsort { borrows: $1 }
```

- `requires:` 会对照编译命令行进行**检查**。与之相矛盾的构建是一个错误
  （`CONTRACT_PACKAGE_MISMATCH`）—— 这些契约是为另一种构建编写的，因此它们所承诺的可能
  并不成立。编译命令行无法确定的条件会被报告为 *unverified*，绝不会被视为已满足。
- `version:` 作为**声明值**携带。kenbi 无法从源代码中读出库的版本，也不假装能够做到；
  报告会写明 "version declared, not verified"。

`--format=json` 携带全部信息（`contractPackages`，含 `versionDeclared`、`requires`、
`mismatched`、`unverified`、`appliesToThisBuild`），因此使用方可以在依赖一组契约之前
决定是否信任它。

### 发布契约集

`--emit-contracts` 打印所分析内容的契约*表面*，而不是检查它 —— 这是库对外提供的形式，
使另一个工具（另一种检查器、绑定生成器、另一种语言的前端）无需重新读取库的注释，即可让
调用方遵守该库的契约：

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

`resources` 是 alloc → free 的词汇：只被告知 deallocator 的使用方，无法判断最初是哪个调用
把义务交给了它。并且每个契约都携带本次运行对其背后实现所确立的 `status`，因为"契约已声明"
绝不能被理解为"实现已被检查"：

| `status` | 本次运行确立了什么 |
|---|---|
| `declared` | 这里没有实现（只有原型，或是从外部编写的契约）—— **没有任何内容被验证** |
| `unchecked` | 函数体存在但不在 `@kenbi` 之下：kenbi 没有检查它 |
| `red` | 函数体在 `@kenbi` 之下，且与其契约相矛盾 —— 不要依赖它 |
| `green` | 已检查且干净，但依赖于信任（一个未覆盖的契约化被调用者，或一个 `@unsafe`） |
| `verified` | 已检查且干净，其整个契约化闭包也是如此：没有残留 |

发布不是检查：即使代码存在问题，文档也会被打印出来，退出码为 0。要获取那些问题，请执行
一次普通的 `kenbi` 运行。

## "GREEN" 与 "verified" 是不同的答案

注解不是证明，覆盖率结果也明确说明了这一点：

| | 含义 |
|---|---|
| `GREEN (contracted)` | 边界已声明 —— 在其所依赖的契约*成立的前提下*是安全的 |
| `verified` | 其整个契约化依赖闭包也被覆盖：没有任何内容是基于信任的 |
| `trusted frontier` | 一个 GREEN 当前所依赖的未覆盖被调用者 —— 覆盖它们即可闭合 |
| `@unsafe vouches` | 作者对 kenbi 无法检查的内容作出断言的位置 |

`verified` 是 `GREEN` 的严格子集。在一个未覆盖的被调用者上声明契约，会使函数从 RED 变为
GREEN，并把该被调用者放到可信前沿上；一个实际抑制了某条结果的 `@unsafe` 会使函数保持
GREEN，且永远不会进入 `verified`，同时指明该位置。因此，一个 kenbi 无法验证的操作，绝不会
因为有人为它加了注解就显示为 verified。所有这些都包含在 `--format=json` 中（`green`、
`verified`、`trustedFrontier`、`unsafeVouches`，以及每个入口点的 `flows` 及其 `blockers`）。

```sh
kenbi --compile-commands=build/compile_commands.json src/img.c
kenbi --project=build/compile_commands.json          # the whole project, one closure
kenbi --emit-contracts src/*.c                       # publish the contract set instead
kenbi --format=json src/*.c
kenbi foo.cpp -- -Iinclude -DDEBUG
```

JSON 文档为 `{ "version", "tool", "findings": [ { "file", "line",
"code", "severity", "message" } ], "coverage", "scope" }`；代码是稳定的，顺序是确定的。读取 / 解析失败会以
`PARSE_ERROR` 结果的形式出现。
`scope` 按每个被分析的文件列出哪些检查在哪些函数上运行：对 `ownership`、`bounds`、`locks`、
`initialisation` 和 `taggedUnions` 中的每一项，`mode` 为 `file`（所有函数）、`functions`（部分函数，其余函数的名字列在
`unchecked` 中）或 `off`，另外还列出在其余未检查的函数内部由 `@kenbi` 采用的代码块。没有结果的文件只在这个范围内是干净的；
文本输出会在每个文件下方打印它。

## 注解

资源在注释中声明，并以带作用域、项目内唯一的名称引用。义务归属于*分配*
（其"origin"），而非变量：拷贝是它的别名，内部指针由它派生，而 `free` / move
履行该义务。分支以健全的方式合并（某状态在汇合点之后可能成立，当且仅当它在*任一*
路径上可能成立 —— 因此只在一条路径上释放，仍会在另一条路径上留下泄漏）。

```c
/* @mem demo::buf { size: n, free: free, owner: p } */
char *p = malloc(n);     // alloc of demo::buf (p is the owner)
char *r = p + 16;        // interior pointer — inferred, must not be freed
consume(p);              // use
sink(p);  // @move demo::buf   — obligation transferred out; p is now moved-from
```

- **分配**：右侧为 `malloc` 家族或 C++ `new` 的初始化 / 赋值，将义务绑定到目标变量。
- **释放**：`free(p)` 或 C++ 的 `delete`/`delete[] p`。
- **内部指针**：`p + off` 派生出指向同一 origin 的内部指针。
- **别名**：`q = p` 使 `q` 成为 `p` 之 origin 的别名。
- **copy**：赋值上的 `// @copy <resource>` 标记一次*深*拷贝 —— 一个新的、独立的、
  拥有自身义务的被持有对象，而非单纯的别名。
- **move**：带 `// @move` 的那一行上的调用会把义务转移出去。
- **unsafe**：行上的 `// @unsafe` 将其隔离 —— 该处的结果被抑制（由你承担责任）。
  一个未覆盖任何内容的 `@unsafe` 会被报告为 `STALE_UNSAFE`，就像一个未使用的
  lint-disable。
- **null 安全**：声明上的 `// @nullable`（或 `@nonnull`）标记指针是否可能为 null；
  在没有 null 检查（`if (p)`、`if (p != NULL)`、提前 `return`）的情况下解引用一个
  nullable 指针即为 `NULL_DEREF` —— 即 `Option<T>` 纪律，流敏感并带分支收窄。
- **frees 契约**：函数上方的 `// @frees(param)` 声明它会释放该实参。调用点随后将
  该调用视为释放它（因此与 double-free / 泄漏组合检查），并检查函数自身的函数体 ——
  如果它实际上并未释放该参数，即为 `CONTRACT_NOT_HONORED`（声明意图 vs 实现，
  这是没有注解的工具无法检查的）。
- **must-use 返回值**：函数上方的 `// @must_use` 声明其结果必须被消费；其值被丢弃
  的调用（裸语句，未被赋值 / 返回 / 传递 / 测试）即为 `UNUSED_MUST_USE` —— 即针对
  被忽略的错误码和泄漏的分配的 `#[must_use]` 纪律。

### Goto 词汇（可选 —— 声明一个 goto 的结构化意图）

常见的前向 goto 会被自动建模（无需注解）：前向清理阶梯
（`if(!p) goto fail; … fail: free()`）通过 join-merge 分析，从循环/switch 跳出到
清理标签的前向 goto 也被接受。而*后向* goto 循环、跳转到嵌套标签，或计算型 goto
则保持拒绝（`UNSTRUCTURED_GOTO`）—— 以拒绝换取健全。可选的词汇让你能声明一个 goto
的结构化含义，使 kenbi 对其建模并交叉检查其形状：

- 标签上的 `// @goto_noreturn` 标记一个不返回的终点（abort / exit / longjmp）：到达
  它的路径终止，因此其仍被持有的义务被履行 —— abort 路径不算泄漏（抑制 error-abort
  路径上的虚假泄漏）。
- 标签上的 `// @goto_finally` 标记清理汇聚漏斗。一种选择加入的单漏斗纪律：一个仍持有
  资源、却*未*经由该漏斗路由的出口即为 `FINALLY_BYPASSED`（用 `goto <funnel>` 使释放
  在那里发生）。汇聚处的合并完整性仍是常规的推断分析。
- goto 上的 `// @goto_backward` 声明它是一条循环回边：一个简单的 goto 循环会被重构为
  do-while，并由有界不动点分析（因此跨迭代危险会被捕获），而不是被拒绝。

### 边界（`@spatial`）

函数上方或文件级的 `// @spatial` 为该作用域开启边界轴。一个用作缓冲区索引、或决定
`memcpy` 等写入大小的不可信标量参数，必须在路径上存在边界检查 —— `if` 守卫、循环条件、
`% n`、钳位（clamp）或掩码 —— 否则即为 `UNVALIDATED_INDEX` / `UNVALIDATED_SIZE`。该检查
必须覆盖缓冲区（如果存在但过于宽松，则为 `INAPPROPRIATE_BOUND`），有符号索引还需要
`i >= 0`（`INDEX_MAYBE_NEGATIVE`），并且守卫中的算术不得回绕：对无符号 `i` 的
`i + 4 <= n` 不被认可；`n >= 4 && i <= n - 4` 则被认可。kenbi 在路径上寻找该检查；它从不
移除检查。

- 函数上方的 `// @counted_by(<buf>: <len>)` 为指针参数给出其大小，也可以是字段形式
  （`b->buf: b->cap`）或环形缓冲区掩码（`b->mask + 1`）。
- `// @invariant(<field> <rel> <size>)` 声明一个数据结构不变式（例如
  `parser->toknext <= num_tokens`）。该字段随后受到保护：对它的每次写入都需要
  `// @maintains(...)`，kenbi 会对其进行验证（`UNGUARDED_INVARIANT_WRITE`、
  `INVARIANT_NOT_MAINTAINED`），并且以该字段为界的索引通过该关系得到覆盖。

### 初始化（`@initcheck`）与带标签联合体（`@typecheck`）

- 函数上方或文件级的 `// @initcheck`：一个声明时没有初始化器的标量或指针局部变量，必须在
  每条路径上先被赋值再被读取，否则即为 `USE_OF_UNINITIALIZED`。
- `// @typecheck` 加上每个联合体成员的 `// @variant(<member>: <tag> == <value>)`：在其标签
  未被证明（`if (n->tag == 1)`，或对标签的 `case 1:`）的路径上使用该成员，即为
  `TYPE_CONFUSION`。

### C++

`// @raii`（或 `// @raii(Name)`）标记一个其析构函数会释放其所拥有之物的类，kenbi 会检查
析构函数确实这样做。在没有自己的拷贝操作的情况下拷贝这样的类，即为 `MISSING_COPY_CONTROL`；
在读取其源对象之前就进行释放的 `operator=` 即为 `SELF_ASSIGN_UNSAFE`。通过没有虚析构函数的基类
`delete` 派生类对象，即为 `DELETE_NONVIRTUAL_BASE`。`std::unique_ptr` /
`std::shared_ptr`、`std::move`、`.get()` / `.release()` / `.reset()`、lambda，以及异常路径
（`LEAK_ON_THROW`、`try` / `catch`、`noexcept` / `// @nothrow`）均被建模。完整参考由 MCP
服务器以 `kenbi://annotations` 提供（[源文件](mcp/src/annotations.ts)）。

### 并发注解（在 `@threadsafe` 下验证，在其外为建议性）

在 `@threadsafe` 作用域（函数或文件）中，这些注解由持锁 typestate 分析阶段以 default-red
的方式进行**验证**：

- `// @guarded_by(<field>: <lock>)`（用于函数）或 `// @guarded_by(<lock>)`（用于结构体
  成员）：在无法证明持有该锁的情况下进行访问即为 `UNGUARDED_ACCESS`；获取受保护字段的地址
  即为 `GUARDED_ESCAPE`。
- 锁平衡：`LOCK_LEAKED` / `DOUBLE_LOCK` / `UNLOCK_WITHOUT_LOCK`。
- `// @acquires(<lock>)` / `// @releases(<lock>)`：在函数体中验证（`LOCK_NOT_ACQUIRED`），
  并在调用点被使用；被调用者上的 `// @requires_lock(<lock>)`：`REQUIRED_LOCK_NOT_HELD`。
- `// @lock_order(<a> < <b>)`：`LOCK_ORDER_VIOLATION`（AB-BA 死锁 —— 这是 Rust 不提供的
  保证）；相互冲突的声明即为 `LOCK_ORDER_CONFLICT`。`// @lock_class(<X>)` 为锁的身份命名，
  使顺序与契约能够跨函数、跨文件匹配；同一类的两个实例需要一个规范顺序
  （`SAME_CLASS_NO_ORDER`）。
- 函数指针上的 `// @calls(<fn>, ...)`：其声明的目标；在持锁状态下进行的未声明间接调用即为
  `UNDECLARED_INDIRECT_CALL`，超出集合的赋值即为 `UNDECLARED_FN_TARGET`。

在 `@threadsafe` 作用域之外，kenbi 解析这些注解并以 `severity: "advisory"` 输出
（`GUARDED_BY`、`REQUIRES_LOCK`、`ACQUIRES`、`RELEASES`、`LOCK_ORDER`）；**建议性结果
绝不门禁构建** —— 它们是给 AI/人类审查者的指令。`// @llm <freeform>` → `LLM_REVIEW`
是一条自由格式的指令，告诉审查者要检查什么。

### 迷你格式（引擎夹具）

```
@mem <scoped::name> { size: <id>, free: <id>, owner: <id> }
alloc <var> <resource> | copy <dst> <src> | interior <dst> <src> <off>
use <var> | free <var> | move <var> | if / else / endif
```

## 目前可检测

确定性（`error` / `warning`）：`DOUBLE_FREE`、`USE_AFTER_FREE`、
`USE_AFTER_MOVE`、`LEAK`、`FREE_INTERIOR`、`MOVE_INTERIOR`、`FREE_AFTER_MOVE`、
`MOVE_AFTER_FREE`、`DOUBLE_MOVE`、`WRONG_DEALLOCATOR`、`NULL_DEREF`（对可能为 null 的
指针的解引用，以及 —— 单独说明 —— 对 kenbi 已知必为 null 的指针的解引用：
`free(p); p = NULL; *p`，或在一个声明为返回 NULL 的释放之后进行读取）、
`CONTRACT_NOT_HONORED`、`UNUSED_MUST_USE`、`DANGLING_RETURN`（返回指向局部变量
的指针 / 已释放的指针）、`BORROW_FREED`（一个 `@borrows` / arena 对象被单独释放）、
`BORROW_OUTLIVES_OWNER`（在所有者 / arena 已消失后使用）、
`UNCONTRACTED_ESCAPE` / `UNCONTRACTED_RELEASE`（一个被持有的指针越过了未声明任何
所有权契约的被调用者 / 释放边界 —— 即 default-red 纪律）、
`UNSTRUCTURED_GOTO`（kenbi 拒绝建模的后向 / 嵌套 / 计算型 goto）、
`LOOP_FIXPOINT_LIMIT`（分析在迭代上限内未收敛的循环：拒绝，而不是依据不完整的视图判定）、
`LEAK_ON_THROW`（C++：在一个没有 nothrow 保证的被调用者 —— 或一个普通的 `new` —— 可能
展开栈的位置，仍持有裸所有者；RAII 所有者豁免，`noexcept` / `@nothrow` / `-fno-exceptions`
即为证明；在 `try` 内部，展开的出口落入处理程序，处理程序从其汇合点开始检查）、
`FINALLY_BYPASSED`（一个持有资源的出口绕过了声明的 `@goto_finally` 漏斗）、
`FREE_NONHEAP`（对指向栈或其他非堆存储的指针执行 `free`）、`BORROW_MOVED` /
`UNCONTRACTED_MOVE`（从借用中移出，或移入一个未声明接收的被调用者）、
`REALLOC_UNVERIFIED` / `REALLOC_SELF_REASSIGN`（一个在使用前结果未被确定的 `realloc`，或其
唯一句柄被覆盖的 `realloc`）、`MISSING_COPY_CONTROL` / `SELF_ASSIGN_UNSAFE` / `DELETE_NONVIRTUAL_BASE`（C++）、
`UNSUPPORTED_CONSTRUCT`（位于 kenbi 不建模的构造中的分配或释放：拒绝，而不是丢弃），
外加 `UNKNOWN_RESOURCE` / `STALE_UNSAFE` 卫生检查。在选择加入的轴下：`UNVALIDATED_INDEX`、
`UNVALIDATED_SIZE`、`INAPPROPRIATE_BOUND`、`INDEX_MAYBE_NEGATIVE`、
`UNGUARDED_INVARIANT_WRITE`、`INVARIANT_NOT_MAINTAINED`（`@spatial`）、`USE_OF_UNINITIALIZED`
（`@initcheck`）、`TYPE_CONFUSION`（`@typecheck`），以及 `UNGUARDED_ACCESS`、`GUARDED_ESCAPE`、
`LOCK_LEAKED`、`DOUBLE_LOCK`、`UNLOCK_WITHOUT_LOCK`、`LOCK_NOT_ACQUIRED`、
`REQUIRED_LOCK_NOT_HELD`、`LOCK_ORDER_VIOLATION`、`SAME_CLASS_NO_ORDER`、
`UNDECLARED_INDIRECT_CALL`、`UNDECLARED_FN_TARGET`（`@threadsafe`）。循环
（`for`/`while`/`do` 以及声明的 goto 循环）由**有界不动点**分析至收敛，因此跨迭代
危险会被捕获；`break`/`continue` 和前向 goto 清理阶梯被建模；泄漏在每个函数出口处
被检查。

建议性（`advisory` 严重级，绝不门禁 —— 供审查层使用）：`GUARDED_BY`、
`REQUIRES_LOCK`、`ACQUIRES`、`RELEASES`、`LOCK_ORDER`、`LOCK_ORDER_CONFLICT`、
`LLM_REVIEW`、`ESCAPE_UNCHECKED`（所有权被存入 kenbi 不追踪的字段 —— 该边界被
浮现出来，而非被悄然丢弃）、`POSSIBLE_DOUBLE_FREE` / `POSSIBLE_USE_AFTER_FREE`
（一个未契约化的、其可见函数体会释放该实参的被调用者 —— 在声明 `@frees` 之前是一种提示，
声明后即被确认）、`CONTRACT_UNBOUND`（契约指名了一个签名中不存在的参数），以及
`UNKNOWN_VAR`（kenbi 在该处没有为某个句柄记录 origin，因此那里没有进行任何检查 —— 这是
针对 kenbi 自身记账的绊线，绝不是关于代码的断言）。

## 演示：Rust 中的 `unsafe` → 在 kenbi 中得到验证，无需 `@unsafe`

一个带回指（同时有 `prev` *和* `next`）的双向链表，在安全 Rust 中需要 `unsafe`
裸指针（或 `Rc<RefCell<…>>`/`Weak`，那是*运行时*检查的）：借用检查器无法表达这些链接
共享的、循环的所有权 —— 标准库的 `LinkedList` 本身就是用 `unsafe` 构建的。

同样的结构在 kenbi 的 `@arena` 纪律下（[`demo/dll.c`](demo/dll.c)）验证为
**内存安全且无需 `@unsafe`**：

```
$ kenbi demo/dll.c
demo/dll.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

每个节点都活在 arena 中，循环的 `prev`/`next` 指针共享 arena 的生命周期，没有节点被
单独释放，并且在该区域被销毁后不再使用任何东西 —— 全部在所有路径上静态检查。在安全
Rust 被迫使用 `unsafe` 才能*表达*这些循环引用之处，kenbi 在一套声明的、受检查的纪律
下*验证*它们。

**诚实的范围。** 这是在*声明的* `@arena` 纪律下的内存安全（无 use-after-free /
double-free / 泄漏 / use-after-region-free / 单独释放）—— 而**非** Rust 的完整保证：
它不强制 aliasing-XOR-mutation（`&mut`）或数据竞争自由，并且 arena 以内存为代价
（整个区域被一次性释放）换取简单性。这个主张是狭窄而真实的：kenbi 能*承载一套纪律*
（区域所有权），在该纪律下这一模式可被静态检查，而单一模型的语言必须降级到
`unsafe`。对比 [`demo/vec.c`](demo/vec.c)（一个 `Vec<i32>` 等价物）：手动 `malloc`
存入一个结构体字段，验证为干净，但会引发一条 `ESCAPE_UNCHECKED` **建议** —— 该字段的
所有权被诚实地标记为未检查，而非被悄然放过。

## 一个分配器，多个类型化析构函数

真实项目使用一个通用包装函数进行分配，并通过围绕它的类型化析构函数进行释放。因此
`free:` / `free_returns_null:` 接受多个释放函数名 —— 它们都是该家族的有效释放，其他任何
释放仍为 `WRONG_DEALLOCATOR` —— 而 `frees_fields:` 记录这样的析构函数还会释放对象所拥有
的字段：

```c
// @allocator magick::mem { alloc: AcquireQuantumMemory AcquireKernelInfo …,
//                          free_returns_null: RelinquishMagickMemory DestroyKernelInfo …,
//                          frees_fields: DestroyKernelInfo … }
```

在某个字段仍持有所有权时释放容器，默认是 `LEAK` —— 对一个普通的 `free(s)` 而言这是对的，
但对一个本就是为了释放整个对象图而存在的析构函数而言是错的，因此正是声明为其授予许可，
而未声明的释放仍为 RED。

在 ImageMagick 上声明这些配对会使计数**上升**（95 个文件中从 689 增至 729），这是闭包向外
延伸，而非退化：一个 `DestroyKernelInfo(kernel)` 调用之前是一个未契约化的边界 —— kenbi 看不
到那里发生了释放，因此经由它的任何内容都未被检查 —— 现在它是一个 kenbi 会检查的释放，而这又
引出了"谁拥有该对象"的问题。它还发现了一个真实的泄漏：`OrderedDitherImage`（threshold.c）
在 `SetImageStorageClass` 失败时返回，却没有执行其他每个出口都会执行的
`DestroyThresholdMap`。

*以上数字是 2026 年 9 月使用 ImageMagick 7.1.2-27 和当时的 kenbi 测得的；之后版本的 kenbi 报告的总数会有所不同。*

## 为你可能无法编辑的代码添加契约

上面的每个契约都必须位于某个声明的上方 —— 而第三方项目没有地方可以放置它。`@contract`
改为直接指名函数，因此整套词汇都可以在一个强制包含（force-included）的、仅含注释的覆盖层
头文件中使用：

```c
// @contract qsort            { borrows: $1 }
// @contract DestroyKernelInfo { frees: $1 }
// @contract AddValueToSplayTree { borrows: $1, moves: $2 $3 }
```

参数既可以按名称指名，也可以按**位置**（`$1`，从 1 开始）指名，而后者通常正是所需要的：
C 头文件经常以未命名形式声明参数，而需要该契约的调用点只能看到原型。

这是同一个契约，通过同一个绑定解析 —— 因此它是**被检查的，而非被信任的**。对一个函数体
位于翻译单元中的函数所作的 `frees:` 声明，会对照函数体进行验证（如果它没有释放，则为
`CONTRACT_NOT_HONORED`）；释放一个声明为 `borrows:` 的参数即为 `BORROW_FREED`；而声明一个
借用意味着调用方仍负有释放的义务，因此一个被交出却从未被释放的指针会成为一个可见的 `LEAK`，
而不是一个无法判定的边界。一个指名了签名中不存在的参数的契约不会绑定任何东西 —— 该边界仍为
RED（安全的方向），并附带一条说明原因的 `CONTRACT_UNBOUND` 建议。

在 ImageMagick 的 MagickCore 上（95 个文件，使用其自身的编译命令行），
[`demo/imagemagick/kenbi_magick_api.h`](demo/imagemagick/kenbi_magick_api.h) 中的十条
`borrows` 声明将结果从 657 条降至 626 条，`UNCONTRACTED_ESCAPE` 从 249 条降至 216 条 ——
并浮现出两个新的 `LEAK`，这正是机制在起作用：一个声明了的边界就是一个可判定的边界。对于
*工厂*函数，优先使用 `@allocator` —— 将其名称加入某个家族的 `alloc:` 列表，同时也指名了资源
及其 deallocator，因此泄漏和 `WRONG_DEALLOCATOR` 也会得到检查（仅此一项就清除了 xml-tree.c
的 26 个未契约化释放中的 16 个）。

*以上数字是 2026 年 9 月使用 ImageMagick 7.1.2-27 和当时的 kenbi 测得的；之后版本的 kenbi 报告的总数会有所不同。*

## 侵入式链表：声明链接，声明清空

另一种 C 链表 —— 节点位于堆上，通过一个字段串联，逐个释放 —— 不是 arena，而 kenbi 以分配点
为单位的资源模型正是在这里显露出来。每个节点都来自同一个 `malloc`，因此在程序拥有一串对象的
地方，kenbi 只看到了一个资源：遍历中的一次释放被理解为对"该"资源的释放，而下一步则被理解为
释放后使用。

两条声明使这条链变得可检查，并且两者都不是基于信任的：

```c
/* @mem t::n { free: free, owner: cur, link: next } */   /* per resource… */
// @list Cluster { link: next }                           /* …or per record TYPE */

/* @drains(head) */
for (cur = head; cur != NULL; cur = nxt) { nxt = cur->next; free(cur); }
```

`link:` 表明该资源是一个通过该字段串联的集合中的**节点**，因此一次遍历得到的是另一个元素，
而不是一个 kenbi 无法定位的指针，并且遍历中的一次释放移除的是一个**元素**。`@drains(head)`
表明一个循环会释放每一个元素 —— 而 kenbi 会检查这一点：一个什么都不释放的循环即为
`CONTRACT_NOT_HONORED`，一个没有任何循环清空的集合即为 `LEAK`，`free(cur); cur = cur->next;`
即为 `USE_AFTER_FREE`，在游标前进之前将其释放两次即为 `DOUBLE_FREE`，并且一旦集合被清空，
每个游标都成为悬垂指针。

[`demo/list.c`](demo/list.c) 用 30 行展示了全部内容 —— 构建、遍历、清空 —— 并且它验证为
干净：

```
$ kenbi demo/list.c
demo/list.c: ok — no findings from the checks that ran
  checked: ownership; not checked: bounds, locks, initialisation, tagged unions
```

**类型**形式可以触及 kenbi 无法编辑的代码。ImageMagick 的 cluster 链表在
`MagickCore/segment.c` 的九个函数中被遍历；在一个强制包含的覆盖层
（[`demo/imagemagick/kenbi_magick_lists.h`](demo/imagemagick/kenbi_magick_lists.h)）中
加入一行仅含注释的声明，就使该文件的结果从 83 条降至 14 条，全部 54 个 `USE_AFTER_FREE`
和 4 个 `DOUBLE_FREE` 都消失了。头文件无法说明的是哪个循环清空了链表 —— 那是关于某条语句的
事实 —— 因此这些集合在循环处声明清空之前仍保持 RED。这正是 kenbi 应当提出的问题，而不是一个
它能够从文件之外回答的问题。

*以上数字是 2026 年 9 月使用 ImageMagick 7.1.2-27 和当时的 kenbi 测得的；之后版本的 kenbi 报告的总数会有所不同。*

## 配置驱动的底层验证（`--safety`）

底层代码的某些性质根本不在源代码中：哪些函数在中断中运行、设备 API 可以做什么、一次构建
使用多少栈、DMA 引擎可以访问哪些内存。`--safety=project.json` 从项目文件和契约文件中获取
这些性质，并对照它们检查源代码：

```sh
kenbi --format=json --safety=demo/safety/project.json
```

| 性质 | 文档 |
|---|---|
| 调用闭包中被禁止的效应（分配、阻塞、等待、递归），按代码块或函数 | [效应](docs/configured_effects.md)、[递归](docs/configured_recursion.md)、[按状态的效应](docs/configured_state_effects.md) |
| 资源状态机（操作顺序、结束状态、按返回值区分的结果） | [协议](docs/configured_protocols.md)、[结果](docs/configured_protocol_results.md)、[代码块](docs/configured_protocol_blocks.md)、[函数边界](docs/configured_function_boundaries.md) |
| 被异步操作借用的缓冲区（在完成前不得修改、释放或重用） | [异步借用](docs/configured_async_borrows.md)、[容量](docs/configured_borrow_capacity.md)、[对齐](docs/configured_borrow_alignment.md)、[缓冲区标记](docs/configured_buffer_marks.md)、[只读存储](docs/configured_storage_permissions.md) |
| 执行上下文（中断、线程）以及各自允许的 API | [上下文](docs/configured_contexts.md) |
| 读、写及 API 访问的范围与对齐 | [源代码访问](docs/configured_source_access.md)、[API 容量](docs/configured_access_capacity.md)、[API 对齐](docs/configured_access_alignment.md)、[返回的指针](docs/configured_return_pointer.md)、[指针重新赋值](docs/configured_pointer_bindings.md) |
| 有序检查中的循环与计数器 | [for](docs/configured_for_loops.md)、[do-while](docs/configured_do_while.md)、[无符号更新](docs/configured_unsigned_updates.md)、[整数参数](docs/configured_integer_parameters.md) |
| 分配契约、池与堆的上限、内存区域 | [分配](docs/configured_allocation.md)、[内存区域](docs/configured_memory_regions.md) |
| 调用深度与栈使用量（来自编译器的 `-fstack-usage` 输出） | [调用深度](docs/configured_call_depth.md)、[栈使用量](docs/configured_stack_usage.md) |
| MMIO 寄存器映射（只读 / 只写、写 1 清除、读清除、保留位、访问宽度、必需的屏障） | [MMIO](docs/configured_mmio.md) |
| 由外部 WCET 工具提供、与构建绑定的执行时间上界 | [执行时间](docs/configured_execution_time.md) |
| 将契约文件绑定到其编写时所针对的源代码、编译选项和目标 | [制品](docs/configured_contract_artifacts.md)、[编译](docs/configured_contract_compilation.md)、[目标](docs/configured_contract_target.md) |

每项义务都会被报告为 `verified`、`conditional`（在外部契约下成立，结果会将这些契约列为
假设）、`unverified` 或 `violation`。kenbi 无法解析的任何内容都为 `unverified`，并且只有当
每项义务都为 `verified`，或是在项目文件明确接受的假设下为 `conditional` 时，运行才会通过。
上述文档以日语撰写，每份文档都说明了它不涵盖的内容。
[`demo/safety/`](demo/safety/) 和 [`demo/dma/`](demo/dma/) 是基于虚构设备的完整示例。

## GREEN 承诺什么、不承诺什么

GREEN 的含义是：在已运行的检查范围内，在 kenbi 分析过的代码上，每条路径都符合声明的契约。
它并不意味着：

- **在已开启的轴之外也是安全的。** 没有 `@spatial` 的文件没有进行任何边界检查；
  在 `@kenbi` 只标记了文件一部分的情况下，文件其余部分没有进行任何检查。
- **在契约之外也是安全的。** 针对 kenbi 未见过的代码的契约是被信任的，并作为可信前沿列出；
  `@unsafe` 是作者的保证，同样会被列出。`verified` 才是没有任何内容基于信任的答案。
- **在构建所定义的范围之外也是安全的。** 被预处理器排除的代码、另一份
  `compile_commands.json`，或另一个目标平台，都没有被分析。

kenbi 无法建模的内容会被拒绝而不是被跳过：`UNSTRUCTURED_GOTO`（后向 goto、跳转到嵌套标签、
计算型 goto）、`LOOP_FIXPOINT_LIMIT`、`UNSUPPORTED_CONSTRUCT`，以及 `--safety` 下的
`unverified`。在大型真实代码上，这些拒绝是结果的一部分 —— 包含其中之一的函数会保持 RED，
直到它被重构或被声明。

如果你发现了一个本不应为 GREEN 的 GREEN，请附上最小复现进行报告：这是 kenbi 可能存在的
最严重的一类缺陷。

## 架构

分析引擎与前端解耦：它运行在与前端无关的 IR 上，因此解析 C/C++ 是可替换的部分。

```
*.c / *.cpp  ──▶ libclang front-end  ┐
                 (src/frontend_c.nim) ├─▶ Program IR ─▶ typestate engine ─▶ diagnostics
*.mc         ──▶ mini-format parser  ┘   (src/ir.nim)   (src/analyze.nim)
                 (src/parse.nim)
```

| 文件 | 职责 |
|---|---|
| `src/ir.nim` | 与前端无关的 IR（`Program`：资源 + 语句树） |
| `src/analyze.nim` | typestate 引擎（origin、may-set 合并、循环不动点、泄漏扫描、覆盖率） |
| `src/clang.nim` | 最小 libclang FFI（按值结构体与 C ABI 一致） |
| `src/frontend_c.nim`、`src/cfront_*.nim` | 将真实 C/C++ 及注解注释下降为 `Program` |
| `src/annotations/` | 注解词汇的注册表 |
| `src/compile_db.nim` | 从 `compile_commands.json` 提取解析标志 |
| `src/safety_config.nim`、`src/safety_check.nim` | `--safety`：项目文件与契约文件、配置驱动的检查 |
| `src/effect_facts.nim`、`src/protocol_*.nim` | `--safety`：调用闭包效应、状态机与借用 |
| `src/parse.nim` | 迷你格式解析器（引擎夹具） |
| `src/kenbi.nim` | CLI：按扩展名分派，打印诊断 |

## 测试

`tests/*.mc` 直接驱动引擎（17 个用例）。`tests/c/*.c` 与 `tests/cpp/*.cpp` 以真实
C 和 C++ 承载这些场景外加注解专属的检查（349 个用例）；运行器通过 libclang 下降每个
文件，并将产生的诊断 —— **连同其源代码行号** —— 与各文件中的 `//EXPECT CODE` 标记进行
核对（标记位于该行本身，或写作 `//EXPECT CODE@LINE`）。行号错误，或诊断缺失 / 多余，都会
使测试集失败。`tests/run_tests_project.nim` 检查项目范围的覆盖率结果，`tests/run_tests_*.py`
测试集端到端地检查 `--safety`，而 `demo/verify_three_state.py` 检查
[三态语料库](demo/README_three_state.md)以及由其生成的 MCP 服务器材料。

## 许可证

kenbi 采用 Apache License 2.0 授权（[LICENSE.md](LICENSE.md)）。来自其他项目的材料及其许可证记录在
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 中。
