#include <stdlib.h>
// Both functions are GREEN, and neither is verified: `hands_off` rests on the contract of a
// function whose body is not here, and `vouched` on an `@unsafe` assertion.

// @frees(p)
void release_elsewhere(char *p);

// @kenbi
void hands_off(void) {
  /* @mem fixture::buf { free: free, owner: p } */
  char *p = malloc(8);
  release_elsewhere(p);
}

// @kenbi
void vouched(char *given) {
  free(given);   // @unsafe
}
