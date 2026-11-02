#include <stdlib.h>
#include "lib.h"

// @kenbi
// @frees(p)
void lib_release(char *p) {
  free(p);
}

// @kenbi
// @owns
char *lib_make(int n) {
  /* @mem lib::buf { free: free, owner: q } */
  char *q = malloc(n);
  return q;
}
