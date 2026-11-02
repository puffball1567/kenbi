#include <stdlib.h>
void use(char *q);
void f(int k, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  switch (k) {
    case 1: free(p); use(p); break;   // free then use within one case   //EXPECT USE_AFTER_FREE
    default: free(p); break;
  }
}
