#include <stdlib.h>
char *dup_buf(const char *p, int n);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  char *q = dup_buf(p, n);   // @copy demo::buf
  free(p);
  free(q);                   // both obligations discharged -> clean
}
