// SPATIAL: fixed-width binary read/write helpers (cutils.h `get_u32` / `put_u32` etc.)
// access `width` bytes at their `buf + idx` argument. The classic binary-parser OOB is
// `get_u32(buf + pos + 1)` guarded only by `pos < len` — the 4-byte read still reaches
// index `pos + 4`, past the end. kenbi models it as an index at the highest byte
// (`idx + width - 1`), so the loop bound `pos < len` is INAPPROPRIATE for the `pos + 4`
// access; the overflow-safe headroom `len >= 5 && pos <= len - 5` makes it GREEN (the naive
// `pos + 5 <= len` wraps on pos and is RED — see t155). Pilot: quickjs JS_ReadFunctionBytecode.
unsigned get_u32(const unsigned char *p);
void put_u32(unsigned char *p, unsigned v);

// @spatial
// @counted_by(buf: len)
int read_oob(const unsigned char *buf, unsigned len) {
  unsigned pos = 0, acc = 0;
  while (pos < len) {
    acc += buf[pos];                          // OK: pos < len bounds a 1-byte read
    unsigned v = get_u32(buf + pos + 1);   //EXPECT INAPPROPRIATE_BOUND
    acc += v;
    pos += 4;
  }
  return (int)acc;
}

// @spatial
// @counted_by(buf: len)
int read_ok(const unsigned char *buf, unsigned len) {
  unsigned pos = 0, acc = 0;
  while (pos < len) {
    acc += buf[pos];
    if (len >= 5 && pos <= len - 5) {          // OVERFLOW-SAFE: companion `len >= 5` blocks the
      unsigned v = get_u32(buf + pos + 1);     // `len - 5` underflow; arithmetic stays off pos,
      acc += v;                                // so index pos+4 <= len-1. GREEN (was `pos+5<=len`,
    }                                          // the wrap-prone form — now RED, see t155).
    pos += 4;
  }
  return (int)acc;
}

// @spatial
// @counted_by(dst: len)
void write_oob(unsigned char *dst, unsigned len, unsigned i) {
  put_u32(dst + i, 0);   //EXPECT UNVALIDATED_INDEX
}
