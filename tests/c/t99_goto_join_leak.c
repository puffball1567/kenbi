// Soundness of join-merge: a forward goto that jumps OVER a cleanup must not hide a leak.
// On the `!b` path the goto to `done` skips `free(a)`, so `a` leaks on that path. At the
// join the label merges the fall-through (a freed) with the goto state (a still owned), so
// `a` is may-owned at the exit and the leak is reported. The jump cannot launder the
// obligation away — exactly the hole the floor-level refusal protected, now caught while
// admitting the idiom.
#include <stdlib.h>
void f(int n) {
  /* @mem demo::a { free: free, owner: a } */
  char *a = malloc(n);   //EXPECT LEAK
  if (!a) return;
  /* @mem demo::b { free: free, owner: b } */
  char *b = malloc(n);
  if (!b) goto done;
  free(b);
  free(a);
done:
  return;
}
