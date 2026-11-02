// Forward `goto` cleanup ladder — the canonical C error-handling idiom. kenbi models
// it via JOIN-MERGE: each label is a join point that merges the fall-through state with
// every forward goto targeting it. On the `!b` path b is null (carries no obligation)
// and the jump to fail_a correctly SKIPS the (absent) free of b and releases only a; on
// the success path both are freed. No leak, no double free — the idiom is GREEN.
// (A backward goto-loop is still refused — see t98.)
#include <stdlib.h>
void f(int n) {
  /* @mem demo::a { free: free, owner: a } */
  char *a = malloc(n);
  if (!a) return;
  /* @mem demo::b { free: free, owner: b } */
  char *b = malloc(n);
  if (!b) goto fail_a;
  free(b);
fail_a:
  free(a);
}
