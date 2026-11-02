#include <stdlib.h>
void dispose(char *p) {   // same-file body visibly frees p, but declares no @frees
  free(p);                //EXPECT UNCONTRACTED_RELEASE
}
char *f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  dispose(p);        // uncontracted, but visibly frees p   //EXPECT UNCONTRACTED_ESCAPE
  return p;          // returns a maybe-freed pointer to the caller — possible use-after-free   //EXPECT POSSIBLE_USE_AFTER_FREE
}
