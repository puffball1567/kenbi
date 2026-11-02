#include <stdlib.h>
// Opt-in: a kenbi marker turns the file into opt-in mode. The marked function is
// under discipline (its double free is RED); the unmarked function is neutral —
// its identical double free is NOT reported (uncovered code is never a wall of red).
// @kenbi
void marked(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  free(p);
  free(p);                  // COVERED -> reported   //EXPECT DOUBLE_FREE
}
void unmarked(int n) {
  /* @mem demo::buf { free: free, owner: q } */
  char *q = malloc(n);
  free(q);
  free(q);                  // UNCOVERED -> neutral, not reported
}
