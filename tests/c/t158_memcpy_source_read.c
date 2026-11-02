// @spatial
// SPATIAL source-read sink. A copy (memcpy / memmove / strncpy / strncat) also READS its length
// from the SOURCE buffer, not just writes it to the destination. When the source's size is
// DECLARED (@counted_by / fixed array), an untrusted length that can exceed it is a source
// over-read — the Heartbleed class (CVE-2014-0160: copy `payload` bytes from a record holding
// only `rrec_length`). Only a DECLARED source size is checked; an unsized source is the caller's
// contract, not flagged (so ordinary raw-pointer copies stay clean). This header keeps the marker
// file-level so every function below is analysed.
#include <string.h>

// RED: the destination is bounded (n <= dlen), but the length is NOT bounded against the source's
// declared size — a read past the end of `src`.
// @counted_by(src: slen)
// @counted_by(dst: dlen)
void read_oob(unsigned char *dst, unsigned dlen, const unsigned char *src, unsigned slen, unsigned n) {
  if (n <= dlen) memcpy(dst, src, n);   //EXPECT UNVALIDATED_SIZE
}

// GREEN: source and destination share the same declared length, so one bound (n <= len) covers
// both the read and the write.
// @counted_by(src: len)
// @counted_by(dst: len)
void read_ok(unsigned char *dst, const unsigned char *src, unsigned len, unsigned n) {
  if (n <= len) memcpy(dst, src, n);
}

// GREEN (no false positive): the source has NO declared size, so its read is the caller's
// contract and is not flagged — only the destination write is checked.
// @counted_by(dst: dlen)
void unsized_src(unsigned char *dst, unsigned dlen, const unsigned char *src, unsigned n) {
  if (n <= dlen) memcpy(dst, src, n);
}
