#include <stdlib.h>
// @borrows(p)
void consume(void *p);
void sink(void *p);
void f(int n, int c) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  if (c) {
    free(p);
  } else {
    consume(p);   // borrow only -> p still owned on this path
  }
  free(p);          // double free on the then-path (already freed at line 10)   //EXPECT DOUBLE_FREE
}
