// @kenbi
#include <stdlib.h>
// A file-level @kenbi (no function just below it) covers every function in the
// file. So f is under discipline and its double free is RED.
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  free(p);
  free(p);   //EXPECT DOUBLE_FREE
}
