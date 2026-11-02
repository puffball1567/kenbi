#include <stdlib.h>
// A HANDLE ASSIGNED SOMETHING KENBI CANNOT PLACE STOPS NAMING WHAT IT NAMED BEFORE. Every
// binding form recognises one shape of right-hand side; anything else — a pointer read out of
// an untracked field (`cur = cur->next`), the result of an uncontracted call — used to emit
// nothing at all, which silently left the variable naming a resource it no longer points at.
// The next release then read as a DOUBLE_FREE and every later dereference as a USE_AFTER_FREE:
// kenbi accusing correct code of the very bug it exists to find. Now the handle is unbound, and
// releasing it asks the default-red question instead.

typedef struct S { char *buf; struct S *next; } S;
// @borrows(s)
void use(char *s);
static char *source(void);

// a field read is a different object: the release that follows is not a second release of the
// first allocation, it is a release kenbi cannot account for
static void rebound_from_field(S *s) {
  /* @mem t::a { free: free, owner: p } */
  char *p = malloc(8);
  free(p);
  p = s->buf;
  free(p);   //EXPECT UNCONTRACTED_RELEASE
}

// the same for an uncontracted call's result
static void rebound_from_call(void) {
  /* @mem t::b { free: free, owner: q } */
  char *q = malloc(8);
  free(q);
  q = source();
  free(q);   //EXPECT UNCONTRACTED_RELEASE
}

// ONE PATH REBINDS, ANOTHER DOES NOT: the handle may be the resource and may be something
// unplaceable. The "try this, else that" chain is the everyday shape — and it is clean: the
// release still discharges the allocation, so neither allocation is a phantom leak.
static char *fallback(void);
static void try_then_fallback(int n) {
  char *r = NULL;
  if (n > 0) {
    /* @mem t::c { free: free, owner: r } */
    r = malloc(8);
  }
  if (r == NULL)
    r = fallback();
  if (r == NULL) {
    /* @mem t::d { free: free, owner: r } */
    r = malloc(4);
  }
  use(r);
  free(r);
}

// ...but a SECOND release through such a handle is still surfaced — as the possible double
// free it is, not as a verdict kenbi cannot back
static void ambiguous_released_twice(int n) {
  /* @mem t::e { free: free, owner: t } */
  char *t = malloc(8);
  if (n > 0)
    t = source();
  free(t);
  free(t);   //EXPECT POSSIBLE_DOUBLE_FREE
}

// a handle NOBODY rebinds keeps its identity: the cross-iteration double free is still a
// verdict, and so is the zero-trip path on which nothing releases it at all
static void definitely_freed_twice(int n) {
  /* @mem t::f { free: free, owner: u } */
  char *u = malloc(8);   //EXPECT LEAK
  for (int i = 0; i < n; i++)
    free(u);   //EXPECT DOUBLE_FREE
}

// a resource handed OUT through a handle that a sibling path rebound is still handed out:
// the return discharges it, and it is not abandoned
// @owns
static char *returns_either(int n) {
  /* @mem t::g { free: free, owner: v } */
  char *v = malloc(8);
  if (n < 0)
    v = fallback();
  return v;
}
