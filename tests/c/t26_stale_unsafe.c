#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  free(p);  // @unsafe   //EXPECT STALE_UNSAFE
}
