#include <stdlib.h>
// @frees(o)
void rel(char *o);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  rel(p);    // contract frees p
  free(p);   // double free   //EXPECT DOUBLE_FREE
}
