#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  char *q = p;
  free(q);
  consume(p);   //EXPECT USE_AFTER_FREE
}
