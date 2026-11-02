#include <stdlib.h>
// ADVISORY PROMOTION (#B): an uncontracted callee whose VISIBLE body frees a pointer makes a later
// USE / FREE of that pointer unverifiable. kenbi no longer defers this to an advisory hint — the
// missing @frees contract means the ownership transfer's intent is undeclared, and kenbi treats an
// unverifiable transfer as an ERROR (declare-don't-infer / default-red). Declaring @frees on the
// callee resolves it: the use/free becomes a confirmed bug, or @borrows clears it. (Twin of t86,
// which covers the free-after side as POSSIBLE_DOUBLE_FREE.)
void dispose(void *p) {   // same-file body visibly frees p, but declares no @frees
  free(p);                //EXPECT UNCONTRACTED_RELEASE
}
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  dispose(p);             // uncontracted, but visibly frees p   //EXPECT UNCONTRACTED_ESCAPE
  char c = p[0];          // use after the visible free — now an error, not an advisory hint   //EXPECT POSSIBLE_USE_AFTER_FREE
  (void)c;
}
