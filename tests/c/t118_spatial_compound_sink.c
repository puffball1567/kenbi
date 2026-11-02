// @spatial
// SPATIAL soundness: a compound index / length expression is now a SINK. Previously
// `buf[i + 1]` and `memcpy(dst, src, len - 1)` were silently dropped (no ikIndex), so an
// unchecked compound access slipped through as a false GREEN. Now the untrusted base is
// required to be validated, with the offset folded into the requirement.
#include <stdlib.h>
#include <string.h>

extern char dst[64];

// An unguarded neighbour write — no bound present on the path.
void write_neighbour(char *buf, int i) {
  buf[i + 1] = 0;                    //EXPECT UNVALIDATED_INDEX
}

// An unguarded compound length into memcpy.
void copy_minus_one(const char *src, int len) {
  memcpy(dst, src, len - 1);         //EXPECT UNVALIDATED_SIZE
}

// A guarded neighbour read into a heap buffer, bound covers the offset — clean.
int read_neighbour(int n, unsigned int i) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(n);
  int r = 0;
  if (i + 1 < n) {
    r = buf[i + 1];                  // i + 1 < n — covered
  }
  free(buf);
  return r;
}
