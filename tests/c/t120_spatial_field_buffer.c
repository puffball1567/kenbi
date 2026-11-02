// @spatial
// SPATIAL field-direct buffer sink: a fixed-size array MEMBER `s->buf[N]` is a buffer
// like any other — parsers and protocol code index through a struct constantly. kenbi
// reads the member's array size and checks the index / length against it, for both the
// subscript sink (`s->buf[i]`) and the libc length sink (`memcpy(s->buf, …)`).
#include <string.h>

struct Pkt { unsigned char buf[64]; int n; };

// Guarded index into a fixed-size array field — clean.
int read_field(struct Pkt *p, unsigned int i) {
  if (i < 64) {
    return p->buf[i];                // validated against the member's size 64
  }
  return 0;
}

// Unguarded index into the field — no bound present.
int read_field_unguarded(struct Pkt *p, int i) {
  return p->buf[i];                  //EXPECT UNVALIDATED_INDEX
}

// A length written into a fixed-size array field, bounded — clean.
void fill_field(struct Pkt *p, const char *src, size_t len) {
  if (len <= 64) {
    memcpy(p->buf, src, len);        // len <= 64, the field holds 64 — covered
  }
}

// A length into the field with a too-loose bound — INAPPROPRIATE.
void fill_field_loose(struct Pkt *p, const char *src, int len) {
  if (len <= 1000) {
    memcpy(p->buf, src, len);        //EXPECT INAPPROPRIATE_BOUND
  }
}
