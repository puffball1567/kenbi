// @kenbi
#include <stdlib.h>
// GREEN: the checkable idiom REALLOC_SELF_REASSIGN (t177) asks for — the result goes to a temporary
// and the original handle is only overwritten on success (`if (tmp) p = tmp;`), preserving the
// original block on OOM. dst != src so it is not a self-reassign; the fresh-dest realloc is vouched
// with `@realloc` (kenbi cannot flatly verify the reconciliation but still checks the free-once).
void f(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) { return; }
  char *tmp = (char *)realloc(p, n);   // @realloc
  if (tmp) { p = tmp; }
  free(p);
}
