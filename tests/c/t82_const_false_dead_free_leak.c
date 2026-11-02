#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);   //EXPECT LEAK
  if (0) { free(p); }
}
