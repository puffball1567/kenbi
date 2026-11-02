#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  char *r = p + 8;
  sink(p);   // @move demo::buf
  consume(r);   //EXPECT USE_AFTER_MOVE
}
