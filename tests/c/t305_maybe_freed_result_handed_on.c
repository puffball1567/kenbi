// A function that returns what it freed makes its callers' result a maybe-freed handle (t197).
// Handing that handle to a callee with no ownership contract is a use of it, the same as handing
// it to a `@borrows` callee: POSSIBLE_USE_AFTER_FREE. Before, the hand-off to an uncontracted
// callee said nothing, so the caller came out GREEN (Juliet 416 `return_freed_ptr`, `printLine`).
#include <stdlib.h>
void sink_const(const char *s);
void sink_mut(char *s);

static char *gives_freed(void) {
  /* @mem t::z { free: free, owner: p } */
  char *p = malloc(4);
  free(p);
  return p;   //EXPECT DANGLING_RETURN
}

static void to_const(void) {
  char *q = gives_freed();
  sink_const(q);   //EXPECT POSSIBLE_USE_AFTER_FREE
}

static void to_mut(void) {
  char *q = gives_freed();
  sink_mut(q);   //EXPECT POSSIBLE_USE_AFTER_FREE
}

// an owned allocation handed to the same callee is still the uncontracted escape it was
static void owned_to_const(void) {
  /* @mem t::w { free: free, owner: q } */
  char *q = malloc(4);
  sink_const(q);   //EXPECT UNCONTRACTED_ESCAPE
  free(q);
}
