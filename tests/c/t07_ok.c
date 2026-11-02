#include <stdlib.h>
// @borrows(p)
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  consume(p);   // a declared borrow — not an escape, no transfer
  free(p);      // obligation discharged here -> clean
}
