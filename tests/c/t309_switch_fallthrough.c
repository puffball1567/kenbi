#include <setjmp.h>
#include <stdlib.h>
// SWITCH FALL-THROUGH. A case group that can reach its end runs on into the next one, so the
// code entered at a label is that group followed by every group it falls into, up to one that
// ends in a jump (`break`, `return`, `continue`, `goto`, `throw`, `longjmp`). Each such path is
// analysed: a release repeated along it is a double free, and a group that ends in a `break` does
// not run the next one. A finding in a group reached from several labels is reported once.

// case 1 frees, then falls into case 2, which frees again
int fall_double(int c) {
  /* @mem t::a { alloc: malloc, free: free, owner: x } */
  char *x = malloc(8);
  if (!x) return -1;
  switch (c) {
  case 1:
    free(x);
    /* fall through */
  case 2:
    free(x);                                      //EXPECT DOUBLE_FREE
    return -1;
  default:
    free(x);
    return 0;
  }
}

// the same frees with a `break` between them: one free on every path — clean
int no_fall(int c) {
  /* @mem t::b { alloc: malloc, free: free, owner: y } */
  char *y = malloc(8);
  if (!y) return -1;
  switch (c) {
  case 1:
    free(y);
    break;
  case 2:
    free(y);
    break;
  default:
    free(y);
    break;
  }
  return 0;
}

// case 1 frees and allocates again; the case it falls into releases the new block — clean
int alloc_then_fall(int c) {
  /* @mem t::c { alloc: malloc, free: free, owner: z } */
  char *z = malloc(4);
  if (!z) return -1;
  switch (c) {
  case 1:
    free(z);
    z = malloc(8);
    if (!z) return -1;
    /* fall through */
  case 2:
    free(z);
    return 1;
  default:
    free(z);
    return 0;
  }
}

// a chain: case 1 falls through case 2 (which only counts) into case 3, which frees what case 1 freed
int chain(int c) {
  /* @mem t::d { alloc: malloc, free: free, owner: w } */
  char *w = malloc(8);
  int n = 0;
  if (!w) return -1;
  switch (c) {
  case 1:
    free(w);
  case 2:
    n++;
  case 3:
    free(w);                                      //EXPECT DOUBLE_FREE
    return n;
  default:
    free(w);
    return 0;
  }
}

// an `if` whose branches both leave does not fall through — clean
int both_leave(int c, int d) {
  /* @mem t::e { alloc: malloc, free: free, owner: v } */
  char *v = malloc(8);
  if (!v) return -1;
  switch (c) {
  case 1:
    free(v);
    if (d) return 1; else return 2;
  case 2:
    free(v);
    return 3;
  default:
    free(v);
    return 0;
  }
}

static jmp_buf env;

// @longjmps_to(env)
static void fail(void) { longjmp(env, 1); }

// on a setjmp: the first return enters case 0 and falls into case 1, which a longjmp also enters.
// `first` and `n` are changed on the first return, so where a jump lands their values are
// indeterminate (assigning `n` there is not a use of it)
int landing_fall(int c) {
  int n = 0;
  int first = 0;
  switch (setjmp(env)) {
  case 0:
    first = 1;
    /* fall through */
  case 1:
    n = c;
    fail();
    return first;                                 //EXPECT SETJMP_CLOBBERED
  default:
    return n;                                     //EXPECT SETJMP_CLOBBERED
  }
}

// ... and with a `break` after case 0, `n` changes only where a jump lands — clean
int landing_no_fall(int c) {
  int n = 0;
  switch (setjmp(env)) {
  case 0:
    break;
  case 1:
    n = c;
    return 1;
  default:
    return n;
  }
  fail();
  return 0;
}
// @kenbi
