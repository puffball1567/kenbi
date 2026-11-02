#include <stdlib.h>
// Only `adopted` is under `@kenbi`, so only it is checked for ownership: the double release in
// `not_adopted` is outside the checks that ran. A finding-free result must say so.

// @kenbi
void adopted(void) {
  /* @mem fixture::buf { free: free, owner: p } */
  char *p = malloc(8);
  free(p);
}

void not_adopted(void) {
  char *p = malloc(8);
  free(p);
  free(p);
}
