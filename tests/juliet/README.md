# Juliet (NIST SARD) FP/FN harness

This harness measures kenbi's false-positive / false-negative rate on external code,
not on cases written for kenbi. This harness runs kenbi over the
[NIST SARD Juliet Test Suite for C/C++](https://samate.nist.gov/SARD/test-suites/112)
(public domain, CC0) and scores it honestly.

## Corpus (not vendored)

The corpus is large (~105k files) and external, so it is **referenced, not
committed**. Clone it anywhere and point the harness at it:

```
git clone --depth 1 https://github.com/arichardson/juliet-test-suite-c.git ../juliet
export KENBI_JULIET=../juliet     # default if unset
```

Only this harness is committed; the corpus stays out of the repo (delete the clone when
done). The current results are in [RESULTS.md](RESULTS.md).

## Scope

The harness scores the CWEs that map to kenbi's temporal / lifetime diagnostics. kenbi's other
axes (bounds, initialisation, type confusion, locking) are not measured by it:

| Juliet CWE | kenbi class | un-annotated? |
|---|---|---|
| CWE415 Double Free | `DOUBLE_FREE` | yes |
| CWE416 Use After Free | `USE_AFTER_FREE` | yes |
| CWE401 Memory Leak | `LEAK` | yes |
| CWE562 Return of Stack Variable Address | `DANGLING_RETURN` | yes |
| CWE761 Free Pointer Not at Start | `FREE_INTERIOR` | mostly |
| CWE590 Free Memory Not on Heap | `WRONG_DEALLOCATOR` | partial |
| CWE476 NULL Pointer Dereference | `NULL_DEREF` | needs `@nullable` |

The temporal core tracks libc `malloc`/`free` with **no annotation** (an
`UNKNOWN_RESOURCE` *warning* invites a `@mem` declaration but the error still
fires). Cross-function flow variants (`_5x`/`_6x`) need `@frees`/`@owns` contracts;
un-annotated they are both under-detected (FN) and can mis-report (see below).

## Scoring method — function-range × class-specific

A Juliet file packs one `*_bad` function (the flaw) and several `good*` functions
(no flaw of this class) into one file. Defect classes report at different points
(double-free at the sink free, leak at the allocation, UAF at the use), so the
manifest's flaw line and kenbi's report line legitimately differ by several lines.
We therefore match at **function-range granularity**, not line proximity, and only
count **error-severity** findings (warnings/advisories are separate channels).

- **TP** = the `*_bad` function contains a matching-class error
- **FN** = the `*_bad` function has no matching-class error (a miss)
- **FP same-class** = a `good*` function contains a matching-class error
- **FP any-class** = a `good*` function contains an error of *any* class
  (SARD-strict: a good function should be completely silent)
- **incidental** = other-class errors, reported (with an in-good count) but not
  scored into FP — folding them in would be dishonest, because many are real

### Why two FP numbers — and why "any-class FP" ≠ "kenbi wrong"

The any-class FP bucket is a **mix**, verified by reading real cases:

1. **Defensible (kenbi is stricter than Juliet, not wrong).** Using the *value* of
   a freed pointer is undefined behaviour in C even without a dereference
   (C11/C17 §6.2.4, §7.22.3, Annex J.2): `free(p); sink(p);` and `free(p); return p;`
   are UB. Juliet labels such `good*` functions clean (its "use" = deref / double
   free); kenbi flags them (`USE_AFTER_FREE` / `DANGLING_RETURN`). These are real
   UB that Juliet's ground truth under-labels — a strength on safety-critical /
   capability (CHERI) targets, friction on mainstream code.
2. **Genuine FP (kenbi wrong, fixable).** e.g. `if(1) { free(data); }` — a constant
   condition kenbi does not fold, so the impossible not-taken path looks like a
   leak. A precision gap, not UB.

Keep these separated when reporting; never quote "any-class FP" as if it were all
genuine error.

## Usage

```
nim c -r tests/juliet/harness.nim <CWE-dir> [CLASS] [--limit=N] [--juliet=PATH]
                                  [--annotate] [--lang=c|cpp|all] [--fn-list]
```

Run from the kenbi repo root (uses `./kenbi` — build it first). `CLASS` defaults
from the CWE number; `PATH` defaults to `$KENBI_JULIET` or `../juliet`. `--annotate` adds the
declarations described in [RESULTS.md](RESULTS.md#what-was-measured), `--lang` picks the C or
C++ testcases (C by default), and `--fn-list` names every miss and flagged good function.

```
nim c --hints:off -o:tests/juliet/harness tests/juliet/harness.nim
./tests/juliet/harness CWE415_Double_Free
./tests/juliet/harness CWE416_Use_After_Free --limit=50
```
