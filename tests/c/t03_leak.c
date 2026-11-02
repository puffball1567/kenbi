#include <stdlib.h>
// @borrows(p)
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);   //EXPECT LEAK
  consume(p);   // a declared borrow — not an escape; p stays owned -> leaks
}
