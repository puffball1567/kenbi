#include <setjmp.h>
#include <stdlib.h>
// NON-LOCAL JUMPS. A call to `longjmp` leaves the function without running anything after it, and
// a call to a function declared `@longjmps` may. Whatever the caller still owns at such a call is
// lost on that path: LEAK_ON_LONGJMP. A function that can reach a longjmp — directly, or through a
// callee declared `@longjmps` — must declare it too (UNDECLARED_LONGJMP), so the obligation travels
// up the call chain to every caller. A library function is declared by name (`@longjmps(name)` or
// `@contract name { longjmps }`), the form an overlay header uses for code you cannot edit. A
// function that calls `setjmp` is a landing site, which is not modelled yet (UNSUPPORTED_SETJMP).

static jmp_buf env;

void lib_error(const char *msg);      // a library's error handler: it longjmps (declared below)
void lib_fail(int code);              // ... the same, declared through @contract
/* @longjmps(lib_error) */
/* @contract lib_fail { longjmps } */

// @longjmps
void fail(int c) { if (c) longjmp(env, 1); }

// @longjmps
void fail_through(int c) { fail(c); }

void undeclared(int c) {
  fail(c);                                      //EXPECT UNDECLARED_LONGJMP
}

void undeclared_direct(void) {
  longjmp(env, 2);                              //EXPECT UNDECLARED_LONGJMP
}

// @longjmps
void held_across_jump(int c) {
  /* @mem t::a { alloc: malloc, free: free, owner: p } */
  char *p = malloc(8);
  if (!p) return;
  if (c) longjmp(env, 1);                       //EXPECT LEAK_ON_LONGJMP
  free(p);
}

// @longjmps
void held_across_call(int c) {
  /* @mem t::b { alloc: malloc, free: free, owner: q } */
  char *q = malloc(8);
  if (!q) return;
  fail(c);                                      //EXPECT LEAK_ON_LONGJMP
  free(q);
}

// released before the jump: nothing is lost, and nothing after `longjmp` is reached
// @longjmps
void released_first(int c) {
  /* @mem t::c { alloc: malloc, free: free, owner: r } */
  char *r = malloc(8);
  if (!r) return;
  if (c) { free(r); longjmp(env, 1); }
  free(r);
}

// a library function declared by name, both forms
// @longjmps
void through_library(int c) {
  /* @mem t::d { alloc: malloc, free: free, owner: s } */
  char *s = malloc(8);
  if (!s) return;
  if (c) lib_error("bad");                      //EXPECT LEAK_ON_LONGJMP
  else lib_fail(c);
  free(s);
}

void library_undeclared(void) {
  lib_fail(1);                                  //EXPECT UNDECLARED_LONGJMP
}

// nothing held, nothing reaching a jump: clean
int plain(int c) { return c + 1; }

int landing(void) {
  if (setjmp(env)) return 1;                    //EXPECT UNSUPPORTED_SETJMP
  fail_through(1);
  return 0;
}
// @kenbi
