#include <stdlib.h>
// an uncontracted callee: only a prototype, no @frees / @borrows / @moves, and
// not a known-safe libc borrow. Passing an owned pointer to it cannot be
// verified (it may free / borrow / store p), so it is a default-red escape.
void process(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  process(p);   // owned p crosses an uncontracted boundary   //EXPECT UNCONTRACTED_ESCAPE
  free(p);
}
