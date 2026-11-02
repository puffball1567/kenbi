#include <cstdlib>
// A RELEASE IS A RELEASE WHICHEVER SPELLING IT HAS. `delete p` is an expression, not a call,
// and three separate places asked "is this a call to a deallocator?" — so a C++ body that
// releases through `delete` looked, to each of them, like a body that releases nothing. The
// identical `malloc`/`free` code was checked; the `new`/`delete` half was silent.

// --- 1. the callee's VISIBLE body releases, but declares no contract -----------------------
// The caller cannot see a contract, so it must not assume the callee left its pointer alone.
// This is the same POSSIBLE_DOUBLE_FREE the `free(p)` form has always produced.
static void sink_deletes(int *p) {
  delete p;
}

// @kenbi
static void caller_releases_again(void) {
  /* @mem t::a { free: delete, owner: p } */
  int *p = new int;
  sink_deletes(p);   //EXPECT UNCONTRACTED_ESCAPE
  delete p;   //EXPECT POSSIBLE_DOUBLE_FREE
}

// --- 2. a body that releases what it RETURNS hands out a dangling pointer ------------------
// The scan that records this used to skip any function with no parameters, so a parameterless
// factory that frees the pointer it returns warned nobody. (No `@kenbi` here: this function is
// unadopted, so its own findings are neutral — what is under test is what its CALLER learns.)
static int *make_and_delete(void) {
  int *q = new int;
  delete q;
  return q;
}

// @kenbi
static void releases_the_dangling_result(void) {
  int *r = make_and_delete();
  delete r;   //EXPECT POSSIBLE_DOUBLE_FREE
}

// --- 3. `delete` of a handle kenbi cannot account for -------------------------------------
// Default-red on the intake side: an undeclared incoming parameter, and an untracked local
// from an uncontracted factory, are both releases kenbi cannot check. Neither emitted
// anything at all before — the strongest guarantee in the checker did not reach `delete`.
int *opaque_factory(void);

// @kenbi
static void deletes_an_undeclared_param(int *given) {
  delete given;   //EXPECT UNCONTRACTED_RELEASE
}

// @kenbi
static void deletes_an_unaccounted_local(void) {
  int *s = opaque_factory();
  delete s;   //EXPECT UNCONTRACTED_RELEASE
}
