#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  if (1) { free(p); }
}
