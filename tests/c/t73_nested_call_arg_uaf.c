#include <stdlib.h>
int g(char *q);
void h(int x);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  free(p);
  h(g(p));                  // g(p) is a nested call arg -> use of freed p   //EXPECT USE_AFTER_FREE
}
