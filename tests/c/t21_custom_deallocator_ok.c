#include <stdlib.h>
void g_free(void *p);
void f(int n) {
  /* @mem demo::buf { free: g_free, owner: p } */
  char *p = malloc(n);
  g_free(p);          // matches declared deallocator -> clean (also: recognised as release)
}
