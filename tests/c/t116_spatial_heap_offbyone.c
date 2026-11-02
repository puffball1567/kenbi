// @spatial
// SPATIAL strictness for variable-size buffers. An INDEX into a buffer of `n` elements
// must be STRICTLY less than `n` (`idx < n`); a `<=` bound is off-by-one (`idx == n` is
// out of range) -> INAPPROPRIATE_BOUND. A SIZE / length, by contrast, may be `<= n`
// (writing n bytes into an n-byte buffer is fine). A constant bound on a variable-size
// buffer cannot be confirmed to cover it -> RED (bound it by the buffer's own count).
// (Buffers freed + `@mem`-declared so only the spatial findings are under test.)
#include <stdlib.h>
#include <string.h>

// `idx <= n` into a buffer of n elements: off-by-one (idx can equal n).
int index_le(int n, int idx) {
  /* @mem demo::buf { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx <= n) {
    r = buf[idx];                    //EXPECT INAPPROPRIATE_BOUND
  }
  free(buf);
  return r;
}

// `len <= cap` into a cap-byte buffer: appropriate for a length sink — clean.
void size_le(int cap, const char *src, size_t len) {
  /* @mem demo::dst { free: free, owner: dst } */
  char *dst = malloc(cap);
  if (len <= cap) {
    memcpy(dst, src, len);           // a length may equal the size — covered
  }
  free(dst);
}

// A constant bound on a variable-size buffer: kenbi cannot confirm the constant covers
// the runtime size.
int const_bound_var_buf(int n, int idx) {
  /* @mem demo::buf { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < 256) {
    r = buf[idx];                    //EXPECT UNVALIDATED_INDEX
  }
  free(buf);
  return r;
}
