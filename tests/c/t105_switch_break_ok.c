// `break` inside a switch exits the SWITCH (a normal case exit), not any enclosing loop.
// Each case frees its own freshly-allocated resource and breaks; the post-switch join
// merges the case exits. No false cross-case double free, no leak.
#include <stdlib.h>
void f(int k) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);
  switch (k) {
  case 1:
    free(p);
    break;
  default:
    free(p);
    break;
  }
}
