# Juliet results — temporal memory safety, C and C++

These are kenbi's results on the temporal-safety classes of the NIST SARD Juliet Test Suite for
C/C++, measured with the harness in this directory. They were measured with the kenbi and the
harness of the commit that last changed this file; rerun the commands below to reproduce them.

## What was measured

- **Corpus**: Juliet Test Suite for C/C++ 1.3, from the mirror
  <https://github.com/arichardson/juliet-test-suite-c> (commit
  `f88433e3443648a17671398797a04ea1f8e1a274`). Not included in this repository.
- **Classes**: CWE-415 Double Free (`DOUBLE_FREE`), CWE-416 Use After Free (`USE_AFTER_FREE`),
  CWE-401 Memory Leak (`LEAK`), each in C and in C++. Every testcase of these three CWEs is
  included.
- **Toolchain**: libclang 14 (Ubuntu clang 14.0.0). C++ is analysed with `-fno-exceptions`: the
  class under measurement is the memory defect, not `LEAK_ON_THROW`.
- **Annotations**: kenbi is default-red — an allocation nobody declared is reported as such — so
  an unannotated run mostly measures that the code is undeclared. With `--annotate` the harness
  adds the declarations a developer would write, derived from what each function does and
  applied identically to bad and good functions: `@mem` at every allocation, `@frees` on every
  function that releases a parameter (and its accessor forms `*p`, `p.f`, `arr[2]`, globals),
  `@owns` for functions that hand back or fill in an allocation, `@borrows` for the Juliet
  support functions that only read, `@calls` for function-pointer locals, and `@raii` for classes
  whose constructor allocates into a member. It never marks a defect.
- **Scoring**: function by function (see [README.md](README.md#scoring-method--function-range--class-specific)).
  A bad function is detected when kenbi reports the testcase's class in it. Only error-severity
  findings count.

## Reproduce

```sh
nimble build -d:release
nim c -d:release -o:tests/juliet/harness tests/juliet/harness.nim
export KENBI_JULIET=/path/to/juliet-test-suite-c
./tests/juliet/harness CWE415_Double_Free    --annotate --lang=c     # or --lang=cpp
./tests/juliet/harness CWE416_Use_After_Free --annotate --lang=c
./tests/juliet/harness CWE401_Memory_Leak    --annotate --lang=c
```

`--fn-list` prints every miss and every flagged good function by name.

## Results

### Defects (bad functions)

| CWE | lang | bad functions | detected (recall) | SILENT | reported elsewhere in the testcase | reported under another class |
|---|---|---|---|---|---|---|
| 415 Double Free | C | 228 | 198 (86.8%) | **0** | 0 | 30 |
| 415 Double Free | C++ | 774 | 642 (82.9%) | **0** | 40 | 92 |
| 416 Use After Free | C | 156 | 156 (100%) | **0** | 0 | 0 |
| 416 Use After Free | C++ | 321 | 320 (99.7%) | **0** | 0 | 1 |
| 401 Memory Leak | C | 868 | 868 (100%) | **0** | 0 | 0 |
| 401 Memory Leak | C++ | 830 | 788 (94.9%) | **0** | 41 | 1 |

**SILENT** is the number kenbi's soundness is judged on: defects about which kenbi reports nothing
anywhere in their testcase, so that the code would pass. It is zero in all six. Every miss is
therefore one of two kinds, and in both the code is RED:

- **reported elsewhere in the testcase** — the defect is reported where it lives, in a file or a
  class member the per-function scoring does not attribute to the bad function. Juliet's flow
  variant 83, for example, puts the whole source and sink in a class implementation file.
- **reported under another class** — the bad function is RED for a different reason. A freed
  pointer handed to a sink in another file is a `USE_AFTER_FREE` at the hand-off (passing a freed
  pointer's value is itself undefined behaviour); that the sink then frees it again is a fact
  about a body the translation unit does not contain. A release whose origin no contract can
  describe stays `UNCONTRACTED_RELEASE`.

### False positives (good functions)

| CWE | lang | good functions | same class | any class | UB Juliet labels clean | leak Juliet documents | leak to review | other |
|---|---|---|---|---|---|---|---|---|
| 415 | C | 1140 | 6 (0.5%) | 216 (18.9%) | 96 | 0 | 96 | 24 |
| 415 | C++ | 3624 | 14 (0.4%) | 718 (19.8%) | 344 | 0 | 244 | 130 |
| 416 | C | 607 | 6 (1.0%) | 235 (38.7%) | 6 | 229 | 0 | 0 |
| 416 | C++ | 1462 | 14 (1.0%) | 516 (35.3%) | 14 | 502 | 0 | 0 |
| 401 | C | 4094 | 326 (8.0%) | 446 (10.9%) | 0 | 0 | 326 | 120 |
| 401 | C++ | 3876 | 262 (6.8%) | 516 (13.3%) | 68 | 0 | 262 | 186 |

*Same class* counts good functions flagged with the testcase's own class; *any class* counts good
functions flagged with any error at all, which is how strictly SARD defines a good function. The
any-class column splits as follows:

- **UB Juliet labels clean** — the only findings in the function are undefined behaviour that the
  corpus does not count as a defect: using the value of a freed pointer (`free(p); sink(p);`,
  C11/C17 6.2.4, 7.22.3) or deleting an object of a derived class through a base class without a
  virtual destructor (C++ [expr.delete]; Juliet's polymorphic sinks in variants 82 and 84 do
  this). kenbi is stricter than the corpus here, not wrong.
- **leak Juliet documents** — the function leaks, and the testcase says so in a comment
  (`POTENTIAL INCIDENTAL - Possible memory leak here`). A true finding of a class the testcase
  is not filed under.
- **leak to review** — mostly a known false positive: variants 09–14 guard the allocation and the
  release with different `extern` constants (`GLOBAL_CONST_TRUE` / `GLOBAL_CONST_FALSE`) defined
  in another file, so the path that allocates and does not release is one a single-file analysis
  has to consider reachable. Closing it would take constant values from another translation unit.
- **other** — mostly `UNCONTRACTED_RELEASE` / `UNCONTRACTED_ESCAPE` and `CONTRACT_NOT_HONORED`: a
  boundary the generated annotations do not declare. These are default-red refusals, not claims
  of a defect.

## Defects in kenbi found by this measurement

Measuring is how kenbi's own false GREENs have been found. Each was fixed in the engine with a
regression test, never by adjusting the scoring. The most recent:

- An assignment from `new struct S` (an elaborated type name after `new`) has no valid source
  extent in libclang 14, so kenbi could not read the assignment's operator and dropped the
  statement with the allocation in it: 41 CWE-401 C++ testcases were SILENT.
  (`tests/cpp/t42_new_elaborated_type.cpp`)
- The same path dropped any statement that is an operator expression other than an assignment:
  `free(p), free(p);` reported no double free. A comma statement is now lowered as a sequence,
  and any other operator statement holding a memory operation is refused.
  (`tests/c/t306_operator_statement_memory_op.c`)
- Deleting a derived object through a base class without a virtual destructor was not checked
  (CWE-401 `virtual_destructor_01`). It is now `DELETE_NONVIRTUAL_BASE`.
  (`tests/cpp/t43_delete_nonvirtual_base.cpp`)

## What these numbers do not show

- **Juliet is synthetic.** Each testcase is small and written to exhibit one defect; real code
  has other shapes. kenbi's run on ImageMagick is described in
  [demo/imagemagick/README.md](../../demo/imagemagick/README.md).
- **Only the three temporal classes.** Bounds, initialisation, type confusion and locking are
  checked by kenbi but not measured here.
- **The annotations are generated.** They are what the harness can derive mechanically; a
  developer would declare more boundaries, which is what most of the *other* column needs.
- **Not comparable to published numbers for other tools.** Scoring granularity, Juliet version,
  and configuration differ.
