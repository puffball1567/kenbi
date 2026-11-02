#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { size: n, free: free, owner: p } */
  char *p = malloc(n);
  char *r = p + 16;
  free(r);   //EXPECT FREE_INTERIOR
  free(p);
}
