// `@goto_noreturn` suppresses the false leak on an abort path. The `goto die` path carries
// p still owned, but `die:` aborts (the process terminates), so p is not a real leak. Without
// the annotation the join at `die` would keep p owned and report a spurious LEAK. The normal
// path frees p and returns. Clean.
#include <stdlib.h>
void abort(void);
void f(int n, int err) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  if (err) goto die;
  free(p);
  return;
  // @goto_noreturn
die:
  abort();
}
