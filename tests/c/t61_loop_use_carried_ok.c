#include <stdlib.h>
// @borrows(q)
void sum(char *q);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);
  for (int i = 0; i < n; i++) {
    sum(p);                 // a declared borrow used (not freed) in the loop
  }
  free(p);                  // freed once after the loop -> clean, no false leak
}
