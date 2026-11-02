#include <stdlib.h>
#include "t85_release.h"
// Cross-file confident double free: the @frees(p) contract is declared in
// t85_release.h, the callsite + second free are here. Fully contracted =
// information is sufficient, so kenbi must assert the double free across files
// (not fall back to a humble escape).
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  release(p);   // contract (cross-file): p is freed here
  free(p);      // double free   //EXPECT DOUBLE_FREE
}
