#include <stdlib.h>
// Uncontracted-escape blocker (the RED axis in the per-flow view): handler is covered
// but passes its owned buffer to `raw`, which declares NO contract -> UNCONTRACTED_
// ESCAPE (default-red). handler is therefore RED, not GREEN, and the flow rooted at it
// is blocked by the uncontracted boundary `raw`. Unlike the trusted frontier (a
// contracted-but-unverified callee), this blocker is a confirmed RED boundary.
//COV green=0 verified=0 adopted=1 red=1 frontier=-
//COV flows=1 flow=handler/false/raw

void raw(char *buf);   // no @frees / @borrows / @moves contract

// @kenbi
void handler(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  raw(p);   //EXPECT UNCONTRACTED_ESCAPE
  free(p);
}
