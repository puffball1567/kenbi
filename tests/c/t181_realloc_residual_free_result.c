// @kenbi
#include <stdlib.h>
// RED: the first fresh-dest residual — `q = realloc(p, n); free(q);` with no reconciliation. On OOM
// q is NULL, free(q) is a no-op, and the original block (still held by p) leaks. The release is
// refused (REALLOC_UNVERIFIED: which of q and p names the block is not known here), and the block
// nothing accounts for is the LEAK.
void f(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  char *q = (char *)realloc(p, n);
  free(q);   //EXPECT REALLOC_UNVERIFIED
}
