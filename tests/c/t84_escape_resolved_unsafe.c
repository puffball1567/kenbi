#include <stdlib.h>
void process(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  process(p); // @unsafe   — the engineer accepts the unverifiable boundary
  free(p);
}
