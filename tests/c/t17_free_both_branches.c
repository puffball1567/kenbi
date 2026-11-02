#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n, int c) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  if (c) {
    free(p);
  } else {
    free(p);
  }
}
