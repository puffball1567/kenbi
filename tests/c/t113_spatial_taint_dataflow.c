// @spatial
// SPATIAL taint dataflow: an untrusted length flows through a LOCAL (and through a
// struct-field read) to a buffer write. kenbi follows the scalar value — a copy of an
// unvalidated value stays unvalidated — so the overflow is caught even when it is not
// the parameter used directly. A bound check on the local clears it.
#include <string.h>

extern char dstbuf[64];
struct Hdr { int len; };

void via_local(const char *src, int len) {
  int n = len;                       // copy carries the taint
  memcpy(dstbuf, src, n);            //EXPECT UNVALIDATED_SIZE
}

void via_field(struct Hdr *h, const char *src) {
  int n = h->len;                    // a field read is untrusted
  memcpy(dstbuf, src, n);            //EXPECT UNVALIDATED_SIZE
}

void via_local_bounded(const char *src, size_t len) {
  size_t n = len;
  if (n <= 64) {
    memcpy(dstbuf, src, n);          // bounded on this path — clean
  }
}
