// @spatial
// SPATIAL @counted_by: the `(ptr, len)` parameter pair — a pointer/array parameter sized
// by another parameter — is the single most common buffer shape in C APIs (read(fd, buf,
// n), every parser's parse(js, len), …). `@counted_by(buf: len)` declares the relation so
// a bound naming the size parameter covers the buffer parameter. Without it kenbi cannot
// relate `buf` (a plain pointer of unknown size) to `len`. Found load-bearing by the jsmn
// pilot (it resolved the bulk of jsmn's reds with one declaration per function).
#include <string.h>

// A guarded index into a (ptr, len) buffer — covered.
// @counted_by(buf: len)
int read_at(const char *buf, int len, unsigned int i) {
  if (i < len) {
    return buf[i];                   // buf is sized len, i < len — covered
  }
  return 0;
}

// The same buffer, unguarded — still red (the declaration is not a blanket pass).
// @counted_by(buf: len)
int read_unguarded(const char *buf, int len, int i) {
  return buf[i];                     //EXPECT UNVALIDATED_INDEX
}

// A loop bounded by the size parameter — every buf[i] is covered.
// @counted_by(buf: n)
void scan(char *buf, int n) {
  for (int i = 0; i < n; i++) {
    buf[i] = 0;                      // i < n, buf sized n — covered
  }
}

// A length sink into a (ptr, len) destination — covered when bounded by its size.
// @counted_by(dst: cap)
void fill(char *dst, int cap, const char *src, size_t len) {
  if (len <= cap) {
    memcpy(dst, src, len);           // len <= cap, dst sized cap — covered
  }
}

// A bound naming the WRONG size parameter does not cover the buffer.
// @counted_by(buf: len)
int read_wrong_size(const char *buf, int len, int other, int i) {
  if (i < other) {
    return buf[i];                   //EXPECT UNVALIDATED_INDEX
  }
  return 0;
}
