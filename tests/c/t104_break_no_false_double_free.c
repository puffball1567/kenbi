// `free(p); break;` frees p exactly once — break exits the loop, there is no second
// iteration to double-free it. The bounded fixpoint alone would carry the freed state to
// the loop head and flag a FALSE DOUBLE_FREE on the "next iteration"; routing break to the
// post-loop join (not the back edge) removes that false positive. The 0-trip LEAK is real
// (if the loop never runs, p is never freed) — the only finding here.
#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);   //EXPECT LEAK
  for (int i = 0; i < n; i++) {
    free(p);
    break;
  }
}
