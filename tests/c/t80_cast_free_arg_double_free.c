#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  free((void *)p);
  free((void *)p);   //EXPECT DOUBLE_FREE
}
