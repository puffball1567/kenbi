#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = (char *)malloc(n);
  free(p);
  free(p);   //EXPECT DOUBLE_FREE
}
