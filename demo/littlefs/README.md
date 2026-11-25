# Measuring `--safety` on littlefs

`kenbi --safety` verifies that a function and everything it calls stay clear of the effects a
profile forbids. This directory measures that on real code, against a ground truth kenbi has
no part in producing.

[littlefs](https://github.com/littlefs-project/littlefs) (BSD-3-Clause) documents two
properties of its implementation that can be checked this way: it allocates no heap memory
when built with `LFS_NO_MALLOC`, and it does not recurse. It is not included here; the script
takes a checkout.

```sh
git clone --depth 1 --branch v2.9.3 https://github.com/littlefs-project/littlefs ../littlefs
nimble build -d:release -y
python3 demo/littlefs/evaluate.py --littlefs=../littlefs
```

## Method

For every function littlefs exports, kenbi is asked to verify two profiles — no heap
allocation, no recursion — over the function's whole call closure. Each verdict is compared
with the compiler's call graph for the same source (`gcc -fcallgraph-info` at `-O0`),
completed with the calls a compiler does not draw: a function that names another as a value,
passing it as a callback or assigning it to one, reaches it.

Three runs:

- **default build**: the source as released. Four exported functions reach `malloc`.
- **`LFS_NO_MALLOC` build**: the source as released. None does.
- **seeded faults**: in the `LFS_NO_MALLOC` build, one internal function at a time is given a
  hidden allocation, or a call into a recursive helper (20 functions, both faults: 40
  variants), and every exported function is checked again. The ground truth is recomputed for
  each variant.

A verdict is wrong when kenbi accepts a function whose closure violates the property, or
reports a violation in one whose closure does not.

## Result

littlefs v2.9.3, kenbi 0.2.0 with the changes listed below, libclang 14, gcc 11.4:

| run | verdicts | violations found | accepted | undecided | wrong |
|---|---:|---:|---:|---:|---:|
| default build | 68 | 4 of 4 | 64 | 0 | 0 |
| `LFS_NO_MALLOC` build | 66 | 0 of 0 | 66 | 0 | 0 |
| seeded faults (40 variants) | 2640 | 452 of 452 | 2188 | 0 | 0 |

The two released builds agree with what littlefs documents: with `LFS_NO_MALLOC` no exported
function can reach an allocation, and no exported function recurses in either build.

"Accepted" is `verified` or `conditional`. Most obligations are `conditional`: they hold under
the contracts the project supplies, which the result lists as assumptions.

## What the project had to declare

Nothing in the littlefs sources was changed or annotated. The project file names the two
source files, the profiles and the functions to check, and these contracts:

- the shipped [`contracts/c-library.contracts.json`](../../contracts/c-library.contracts.json)
  for `memcpy`, `strlen` and the other string functions, and the compiler builtins;
- the four block-device callbacks of `struct lfs_config` (`read`, `prog`, `erase`, `sync`)
  and the callback handed to `lfs_fs_traverse`: what the integrator installs there neither
  allocates nor recurses;
- `lfs_dir_traverse` keeps callbacks on an explicit stack and reads them back; the contract
  states that what it reads back is what it was handed;
- `__assert_fail`, `printf`, and in the default build `malloc` and `free`, for the effects
  the allocation model does not cover.

Seven assumptions in all, each accepted by name in the project file. A wrong symbol in a
contract is an input error, not a silent miss.

## What the measurement changed in kenbi

Run as it was before this measurement, kenbi gave no wrong verdict either — and decided 10 of
the 68 obligations of the default build. The other 58 were `unverified`, for three reasons
that are now addressed:

- **`sizeof`.** Every `sizeof` other than of a builtin type or a plain variable was refused as
  possibly evaluating its operand. A `sizeof` whose value is a constant does not (C11
  6.5.3.4p2); only one of a variable length array type is still refused.
- **C library functions.** `memcpy`, `strlen` and the like had no effect model. They are now
  covered by a contract package a project opts into.
- **Calls through function pointers.** These could not be resolved at all. A call through a
  function-pointer parameter now reaches the functions passed for that parameter on the call
  path being followed, including through a function that hands the pointer on and including
  what the body itself assigns to the parameter; a null pointer is nothing to call. Whatever
  remains unknown — a struct field, a parameter of an exported function, a value read back
  from memory — is resolved by a contract on that pointer's symbol, which the finding names.

The seeded-fault run also caught a defect in the first version of that resolution: a callback
assigned to the parameter inside the function (`cb = lfs_dir_traverse_filter;`) was not
followed, so twelve violations were accepted. It is fixed, and
[`tests/run_tests_callbacks.py`](../../tests/run_tests_callbacks.py) covers it.

## Limits of this measurement

- One code base, two properties. The other effects (`block`, `wait`) and the other configured
  checks — protocols, execution contexts, stack usage, MMIO — are not measured here.
- The ground truth is static: it says a call path exists, not that it runs. That is the same
  question kenbi answers, so the comparison is like for like, but neither shows what a given
  execution does.
- The callback edges of the ground truth are read from the source text by name. They were
  checked by hand for this version (nine edges); another version needs the same check.
- The seeded faults are direct: an allocation or a recursive call written in a function's
  body. A fault hidden behind a pointer kenbi has to be told about is only as visible as the
  contract for that pointer is true.
