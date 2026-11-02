#include <stdlib.h>
// ADOPTION AT THE GRANULARITY THE CODE IS ACTUALLY CLEANED UP IN. `@kenbi` marks what is under
// discipline, and a function was the smallest unit it could mark — which is no help inside the
// thousand-line functions that most need it. The same marker now binds to a BLOCK when that is
// what it sits above: the findings inside that block's lines are kept while the rest of the
// function stays neutral, exactly as an unadopted function is.
//
// The function does NOT become adopted. A block under discipline does not put the function
// under it, and the coverage numbers must not say otherwise: such blocks are counted and
// reported on their own line.

// @borrows(p)
void use(char *p);

// a bare block: only what is inside it is checked
static void bare_block(void) {
  char *before = (char *) malloc(8);   /* outside: neutral, as in any unadopted function */
  use(before);

  // @kenbi
  {
    /* @mem t::a { free: free, owner: p } */
    char *p = (char *) malloc(8);   //EXPECT LEAK
    use(p);
  }

  char *after = (char *) malloc(8);    /* outside again */
  use(after);
}

// a control statement: the marker covers the statement it sits above, body included
static void guarded(int n) {
  char *outside = (char *) malloc(8);
  use(outside);
  // @kenbi
  if (n > 0) {
    /* @mem t::b { free: free, owner: q } */
    char *q = (char *) malloc(8);   //EXPECT LEAK
    use(q);
  }
}

// ...and a loop
static void looped(int n) {
  // @kenbi
  for (int i = 0; i < n; i++) {
    /* @mem t::c { free: free, owner: r } */
    char *r = (char *) malloc(8);   //EXPECT LEAK
    use(r);
  }
}

// a marker above a FUNCTION still adopts the whole function — the function binding wins
// @kenbi
static void whole_function(void) {
  /* @mem t::d { free: free, owner: s } */
  char *s = (char *) malloc(8);   //EXPECT LEAK
  use(s);
}
//COV adopted=1 blocks=3 red=1
