#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  { char *p = malloc(n); free(p); }   // inner shadow, freed
  free(p);                            // outer
}
