// Regression: an UNDECLARED allocation (plain malloc, no @mem) that is never
// freed emits UNKNOWN_RESOURCE ("declare it") but NOT a definite LEAK. With the ownership
// model undeclared, kenbi cannot know the pointer must be freed HERE, so asserting a
// "definite leak" would be a false accusation stacked on the honest refusal — the crown
// jewel is to refuse (declare / undecidable), never to false-accuse. Once the resource is
// declared with @mem, the leak scan verifies it (see the declared-resource LEAK tests).
// The expectation set is exact: a stray leak fails.
#include <stdlib.h>

int undeclared_no_leak(int n) {
  char *p = malloc(n);   //EXPECT UNKNOWN_RESOURCE
  (void)p;               // never freed, but undeclared -> only the refusal, no bare LEAK
  return 0;
}
