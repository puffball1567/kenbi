// @kenbi
#include <stdlib.h>
// SOUNDNESS FIX: a dereference (`*p` / `p[i]`) is a USE, so it gets the same liveness checks as a
// plain use. Previously ikDeref only raised the maybe-freed ADVISORY and missed a CONFIRMED
// use-after-free / use-after-move reached through a subscript or star-deref — a false GREEN in the
// UAF class. Now asFreed -> USE_AFTER_FREE and asMoved -> USE_AFTER_MOVE fire on the deref too.

// RED: write through a subscript after the buffer is freed.
void write_after_free(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(n);
  if (!p) { return; }
  free(p);
  p[0] = 'x';            //EXPECT USE_AFTER_FREE
}

// RED: read through a star-deref after the buffer is freed.
void read_after_free(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(n);
  if (!p) { return; }
  free(p);
  char c = *p;           //EXPECT USE_AFTER_FREE
  (void)c;
}

// GREEN: the dereference happens while the buffer is still live.
void deref_while_live(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(n);
  if (!p) { return; }
  p[0] = 'x';
  free(p);
}
