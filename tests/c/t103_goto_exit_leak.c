// Soundness of the loop-exit goto: the jump must not launder an obligation away. The
// normal loop exit frees `p`; the error exit jumps straight to `done`, SKIPPING that
// free, so `p` leaks on the exit path. The join at `done` merges the normal-exit state
// (p freed) with the goto-exit state (p still owned), so `p` is may-owned at function
// end and the leak is reported — the exit edge cannot hide it.
#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);   //EXPECT LEAK
  for (int i = 0; i < n; i++) {
    if (i > 5) goto done;
  }
  free(p);
done:
  return;
}
