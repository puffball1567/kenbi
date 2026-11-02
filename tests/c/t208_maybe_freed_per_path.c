#include <stdlib.h>
// "THIS CALLEE'S BODY FREES THE ARGUMENT" IS A PER-PATH FACT. When an uncontracted callee is
// seen to free what it was passed, every later use of that pointer is a use-after-free risk —
// but only on a path that can reach it. The fact used to be held for the whole function, so the
// commonest shape in C (`if (bad) { destroy(x); return; }`) made every line after the guard a
// risk, including lines the release cannot reach: 490 of ImageMagick's 1135 findings, nearly
// all of them unreachable. It now lives in the per-path state like every other fact about a
// resource, so a branch that returns takes its knowledge with it.

// @borrows(s)
void use(char *s);

// an uncontracted callee whose VISIBLE body frees its argument
static void destroy(char *p) {
  free(p);   //EXPECT UNCONTRACTED_RELEASE
}

// same path: the use after the release really is at risk
static void same_path(void) {
  /* @mem t::a { free: free, owner: p } */
  char *p = malloc(8);
  destroy(p);   //EXPECT UNCONTRACTED_ESCAPE
  use(p);   //EXPECT POSSIBLE_USE_AFTER_FREE
}

// the release is on a branch that RETURNS: the code after the guard is not reached from it
static void returning_branch(int bad) {
  /* @mem t::b { free: free, owner: q } */
  char *q = malloc(8);
  if (bad) {
    destroy(q);   //EXPECT UNCONTRACTED_ESCAPE
    return;
  }
  use(q);
  free(q);
}

// ...and a branch that does NOT return carries the risk into the join, where it belongs
static void non_returning_branch(int bad) {
  /* @mem t::c { free: free, owner: r } */
  char *r = malloc(8);
  if (bad)
    destroy(r);   //EXPECT UNCONTRACTED_ESCAPE
  use(r);   //EXPECT POSSIBLE_USE_AFTER_FREE
}
