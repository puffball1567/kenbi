// A well-formed `@goto_backward` goto-loop is clean: p is borrowed (not freed) each iteration
// and freed once after the loop. do-while semantics avoid a false 0-trip leak, and the
// fixpoint sees no cross-iteration free. Without the declaration the goto-loop is refused.
#include <stdlib.h>
// @borrows(q)
void use(char *q);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);
  int i = 0;
loop:
  use(p);
  i++;
  if (i < n) goto loop;   // @goto_backward
  free(p);
}
