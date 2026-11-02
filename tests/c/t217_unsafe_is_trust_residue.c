#include <stdlib.h>
// AN ANNOTATION IS NOT A PROOF. The coverage model already separated GREEN ("the boundaries are
// declared — modular trust") from VERIFIED ("the whole closure is covered, nothing is taken on
// trust"), and a declared contract on an uncovered callee shows up as the trusted frontier. But
// `@unsafe` — the strongest form of "kenbi cannot check this, I assert it" — was invisible to
// that accounting: a function whose only finding was suppressed by one read as 100% verified,
// with an empty frontier. That is precisely what the distinction exists to prevent.
//
// An effective `@unsafe` now makes its function GREEN but never VERIFIED, and the site is named
// in the coverage result (text and JSON) so a reader — or another tool — can see exactly what
// the GREEN rests on.

// @kenbi
static void asserts_what_kenbi_cannot_check(char *given) {
  free(given);   // @unsafe
}
//COV adopted=1 green=1 verified=0 red=0 unsafeVouches=1
//COV flow=asserts_what_kenbi_cannot_check/false/-
