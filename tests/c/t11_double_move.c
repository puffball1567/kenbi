#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  sink(p);   // @move demo::buf
  sink(p);   // @move demo::buf   //EXPECT DOUBLE_MOVE
}
