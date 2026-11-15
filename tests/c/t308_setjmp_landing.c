#include <setjmp.h>
#include <stdlib.h>
// LANDING SITES. `if (setjmp(b))` at the top level of a function is where a longjmp to `b` returns.
// Every call after it that may jump to `b` is a path into the landing branch, and that branch —
// with whatever follows it — is analysed from the join of those paths: a release that does not
// match on one of them is reported like any other (here a double free). A call whose jmp_buf is
// declared (`@longjmps_to`, `longjmps:` in @contract; `longjmp`'s own first argument) is matched
// against `b` as written; a different buffer means the jump leaves the function instead, and an
// undeclared one is UNKNOWN_LONGJMP_TARGET. A non-volatile local changed after the setjmp and
// read where the jump lands is SETJMP_CLOBBERED (its value is indeterminate there). A declared
// target is checked against the body (LONGJMP_TARGET_MISMATCH). A setjmp in any other form is
// UNSUPPORTED_SETJMP.

static jmp_buf parse_fail;
static jmp_buf other_fail;

typedef struct ctx_s *ctx_t;
jmp_buf *ctx_jmpbuf(ctx_t c);
void ctx_step(ctx_t c);
/* @contract ctx_step { longjmps: *ctx_jmpbuf($1) } */

// @longjmps_to(parse_fail)
static void fail(void) { longjmp(parse_fail, 1); }

// @longjmps_to(other_fail)
static void fail_elsewhere(void) { longjmp(other_fail, 1); }

// @longjmps_to(parse_fail)
static void wrong_target(void) { longjmp(other_fail, 2); }    //EXPECT LONGJMP_TARGET_MISMATCH

// @longjmps
void legacy(int x);

// every path back is released exactly once: clean
// @longjmps
int clean(int c) {
  /* @mem t::a { alloc: malloc, free: free, owner: p } */
  char *volatile p = NULL;
  if (setjmp(parse_fail)) { free(p); return -1; }
  if (c) fail();                                  // p is NULL here: free(NULL) is a no-op
  p = malloc(8);
  if (!p) return -1;
  fail();                                         // p is owned here: the landing frees it
  free(p);
  return 0;
}

// released, then a jump back: the landing releases it again
int released_then_jump(void) {
  /* @mem t::b { alloc: malloc, free: free, owner: q } */
  char *volatile q = malloc(8);
  if (!q) return -1;
  if (setjmp(parse_fail)) {
    free(q);                                      //EXPECT DOUBLE_FREE
    return -1;
  }
  free(q);
  fail();
  return 0;
}

// changed after the setjmp and not volatile: indeterminate where the jump lands
int clobbered(void) {
  /* @mem t::c { alloc: malloc, free: free, owner: r } */
  char *r = NULL;
  if (setjmp(parse_fail)) {
    free(r);                                      //EXPECT SETJMP_CLOBBERED
    return -1;
  }
  r = malloc(8);
  if (!r) return -1;
  fail();
  free(r);
  return 0;
}

// a jump to another buffer leaves the function: what it holds is lost
// @longjmps
int other_buffer(void) {
  /* @mem t::d { alloc: malloc, free: free, owner: s } */
  char *volatile s = NULL;
  if (setjmp(parse_fail)) { free(s); return -1; }
  s = malloc(8);
  if (!s) return -1;
  fail_elsewhere();                               //EXPECT LEAK_ON_LONGJMP
  free(s);
  return 0;
}

// a library function declared through @contract, matched through its argument
int through_contract(ctx_t c) {
  /* @mem t::e { alloc: malloc, free: free, owner: u } */
  char *volatile u = NULL;
  if (setjmp(*ctx_jmpbuf(c))) { free(u); return -1; }
  u = malloc(8);
  if (!u) return -1;
  ctx_step(c);
  free(u);
  return 0;
}

// `if (!setjmp(b))`: the ELSE branch is where the jump lands
int negated(void) {
  /* @mem t::f { alloc: malloc, free: free, owner: v } */
  char *volatile v = malloc(8);
  if (!v) return -1;
  if (!setjmp(parse_fail)) {
    fail();
  } else {
    free(v);
    return -1;
  }
  free(v);
  return 0;
}

// target undeclared: cannot tell whether it returns here
int unknown_target(void) {
  if (setjmp(parse_fail)) return -1;
  legacy(1);                                      //EXPECT UNKNOWN_LONGJMP_TARGET
  return 0;
}

// a setjmp in a form kenbi does not model
int as_switch(void) {
  switch (setjmp(parse_fail)) {                   //EXPECT UNSUPPORTED_SETJMP
  case 0: return 0;
  default: return 1;
  }
}
// @kenbi
