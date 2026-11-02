#include <stdlib.h>
void f(int err) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);
  if (err) {
    free(p);       // disposed before the early return — every exit clean
    return;
  }
  free(p);
}
