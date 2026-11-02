// @kenbi
#include <stdlib.h>
// RED: `p = realloc(p, n)` self-reassign. On OOM realloc returns NULL and overwrites the ONLY
// handle to the original block, which then leaks — irrecoverably (a later null-check cannot bring
// the lost handle back). kenbi's realloc model otherwise tracks only the success path, so it used
// to green this. The fix idiom is the temporary-and-reconcile form (see t178).
void f(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  p = realloc(p, n);   // self-reassign: original leaks if realloc fails   //EXPECT REALLOC_SELF_REASSIGN
  free(p);
}
