// @spatial
// SPATIAL compound guards + offset arithmetic — the everyday parser idiom. kenbi now
// recognises: a `&&` conjunction (lower + upper bound), a variable bound with a `± k`
// offset (the look-ahead `pos + 4 <= len`), and a neighbour access `buf[i + k]` (whose
// bound must cover `i + k`, not just `i`). Matching stays identity-based / no range
// arithmetic. (Buffers freed + @mem-declared so only spatial findings are under test.)
#include <stdlib.h>

extern int table[256];

// `&&` with a fixed array: the i < 256 conjunct covers table[256] — clean.
void both_bounds(int i) {
  if (i >= 0 && i < 256) {
    table[i] = 0;                    // validated by the i < 256 conjunct
  }
}

// Look-ahead, OVERFLOW-SAFE: keep the arithmetic on the trusted limit so the untrusted `pos`
// never wraps. `len >= 4` blocks the `len - 4` underflow; `pos <= len - 4` then bounds
// pos..pos+3 in a len-sized buffer. (The wrap-prone `pos + 4 <= len` form is RED — see
// t155.) `len` is unsigned so the `len - 4` subtraction wraps in a defined way when unguarded.
int lookahead(unsigned len, unsigned int pos) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(len);
  int r = 0;
  if (len >= 4 && pos <= len - 4) {
    r = buf[pos] + buf[pos + 3];     // pos, pos+3 <= len-1 — covered, no wrap on pos
  }
  free(buf);
  return r;
}

// `&&` with a heap buffer sized by the same identifier — clean.
void conj_heap(int n, int i) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(n);
  if (i >= 0 && i < n) {
    buf[i] = 1;                      // validated by i < n
  }
  free(buf);
}

// A neighbour access whose bound does NOT cover the offset: i < n but buf[i+1] reaches n.
int neighbour_short(int n, int i) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(n);
  int r = 0;
  if (i < n) {
    r = buf[i + 1];                  //EXPECT INAPPROPRIATE_BOUND
  }
  free(buf);
  return r;
}

// The look-ahead bound does NOT cover buf[pos + 4] (pos+4 can equal len).
int lookahead_over(int len, int pos) {
  /* @mem demo::buf { free: free, owner: buf } */
  char *buf = malloc(len);
  int r = 0;
  if (pos + 4 <= len) {
    r = buf[pos + 4];                //EXPECT INAPPROPRIATE_BOUND
  }
  free(buf);
  return r;
}
