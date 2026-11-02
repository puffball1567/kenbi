#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { size: n, free: free, owner: p } */
  char *p = malloc(n);
  char *r = p + 4;
  char *s = r + 8;
  free(p);
  consume(s);   //EXPECT USE_AFTER_FREE
}
