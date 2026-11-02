#include <stdlib.h>
void dispose(void *p) {   // same-file definition: visibly frees p, but NO @frees
  free(p);                // intake-side default-red: frees an undeclared pointer param   //EXPECT UNCONTRACTED_RELEASE
}
// dispose frees a pointer parameter it never declared it owns -> UNCONTRACTED_RELEASE
// (the intake-side boundary). On the CALL side, kenbi can SEE dispose frees p but does
// not ASSERT a double free (the contract is unwritten): it keeps the boundary red
// (UNCONTRACTED_ESCAPE) and HINTS the possibility (advisory). Declaring @frees(p) on
// dispose (see t87) resolves BOTH sides at once.
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  dispose(p);   // uncontracted, but visibly frees p   //EXPECT UNCONTRACTED_ESCAPE
  free(p);      // possible double free (advisory, not asserted)   //EXPECT POSSIBLE_DOUBLE_FREE
}
