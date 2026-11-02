// `@goto_backward` declares the back-edge a loop, so the bounded fixpoint analyses it — and
// catches the cross-iteration double free (p is freed every iteration) just as a `for` loop
// would. Without the declaration the goto-loop is refused (UNSTRUCTURED_GOTO). The fix is to
// free p after the loop, or move the alloc inside it.
#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);
  int i = 0;
retry:
  free(p);   //EXPECT DOUBLE_FREE
  i++;
  if (i < n) goto retry;   // @goto_backward
}
