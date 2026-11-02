// One goto kenbi cannot model (a backward jump) no longer drags the function's forward cleanup
// gotos into refusal with it. The backward goto is refused where it stands, which keeps the
// function red; the forward goto to the top-level `out` label is still followed, so the path
// that reaches `out` still owning `p` is reported as the leak it is. Before, every goto in the
// function was refused and treated as falling through, and that leak went unreported.
#include <stdlib.h>
int f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(8);   //EXPECT LEAK
  if (!p) return -1;
  int i = 0;
 again:
  if (n > 3) goto out;
  i++;
  if (i < n) goto again;   //EXPECT UNSTRUCTURED_GOTO
  free(p);
  return 0;
 out:
  return 1;
}
