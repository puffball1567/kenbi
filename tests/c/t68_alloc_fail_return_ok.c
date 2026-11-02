#include <stdlib.h>
// @borrows(q)
void g(int *q);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  int *p = malloc(n * sizeof(int));
  if (!p) return;          // alloc failed: p is null on this path -> not a leak
  g(p);                    // a declared borrow -> not an escape
  free(p);
}
