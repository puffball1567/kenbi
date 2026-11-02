#include <stdlib.h>
// `@frees(g)` where `g` is a file-scope GLOBAL (not a parameter): the (often zero-arg) sink releases
// a resource handed to it through that global. `g = data` aliases the global to data's origin in the
// caller, so a call to the sink frees it there — modular detection of the static-global source/sink
// form (Juliet _45), no whole-program pass. Only fires where the global carries an obligation here.
static char *g;
// @frees(g)
static void badSink(void);   // reads g and frees it (the double-free channel)
static void badSink(void) { char *d = g; free(d); }

// @kenbi
void double_free(void) {
  /* @mem j::b { free: free, owner: data } */
  char *data = (char *)malloc(100);
  free(data);
  g = data;
  badSink();   // frees g (== data) again -> double free through the global   //EXPECT DOUBLE_FREE
}

// @kenbi
void transfer_ok(void) {
  /* @mem j::b { free: free, owner: data } */
  char *data = (char *)malloc(100);
  g = data;
  badSink();   // ownership handed to the sink through the global (frees once) -> clean
}
