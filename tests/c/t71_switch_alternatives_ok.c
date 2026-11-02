#include <stdlib.h>
void f(int k, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  switch (k) {
    case 1: free(p); break;
    case 2: free(p); break;     // a free in a different case is NOT a double free
    default: free(p); break;
  }
}
