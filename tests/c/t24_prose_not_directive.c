#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  // note: we intentionally do not @copy or @move p here
  free(p);
}
