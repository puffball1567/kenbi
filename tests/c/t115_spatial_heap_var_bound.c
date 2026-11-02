// @spatial
// SPATIAL variable-size buffers: a buffer allocated `malloc(n)` (or `malloc(n*sizeof)`
// / `calloc(n,..)`) is covered by a bound that names the SAME identifier — `idx < n`,
// a `for (i=0;i<n;i++)` loop, or `len <= n`. This is the load-bearing case for real
// parsers, which malloc a buffer of a runtime size and index it with a runtime bound.
// Matching is by IDENTITY (no range arithmetic): only the buffer's own count validates.
// (The buffers are freed and `@mem`-declared so the temporal axis stays clean — the
// findings under test are purely the spatial ones.)
#include <stdlib.h>
#include <string.h>

// A guarded index into a heap buffer sized by the same variable — clean.
int read_at(int n, unsigned int idx) {
  /* @mem demo::buf { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < n) {
    r = buf[idx];                    // bound names the buffer's own count — covered
  }
  free(buf);
  return r;
}

// An UNguarded index into the same heap buffer — kenbi cannot confirm it is in range.
int read_unguarded(int n, int idx) {
  /* @mem demo::buf { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = buf[idx];                  //EXPECT UNVALIDATED_INDEX
  free(buf);
  return r;
}

// A loop bounded by the allocation count — every `buf[i]` is covered.
void fill(int n) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(n);
  for (int i = 0; i < n; i++) {
    buf[i] = 0;                      // i < n, buf is n bytes — covered
  }
  free(buf);
}

// A length written into a heap buffer, bounded by the buffer's own size — clean.
void copy_into(int cap, const char *src, size_t len) {
  /* @mem demo::dst { free: free, owner: dst } */
  char *dst = malloc(cap);
  if (len <= cap) {
    memcpy(dst, src, len);           // len <= cap, dst is cap bytes — covered
  }
  free(dst);
}

// The bound names a DIFFERENT variable than the buffer's size — not confirmable.
int read_wrong_var(int n, int m, int idx) {
  /* @mem demo::buf { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < m) {
    r = buf[idx];                    //EXPECT UNVALIDATED_INDEX
  }
  free(buf);
  return r;
}
