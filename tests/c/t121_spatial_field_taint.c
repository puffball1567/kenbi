// @spatial
// SPATIAL field taint: a field READ used as an index / length is an untrusted value,
// like a parameter — a parser reads offsets and lengths straight out of a struct. kenbi
// now tracks the field by its path, so `buf[s->idx]` / `memcpy(dst, src, s->len)` are
// real sinks (default-red) that a guard on the SAME field validates. This closes the
// silent gap where a field-read value reached a sink unchecked.
#include <string.h>
#include <stdlib.h>

extern char dst[64];
struct Hdr { unsigned int idx; size_t len; };

// An unguarded field-read index — no bound present.
int index_by_field(char *buf, struct Hdr *h) {
  return buf[h->idx];                //EXPECT UNVALIDATED_INDEX
}

// An unguarded field-read length into memcpy.
void copy_field_len(const char *src, struct Hdr *h) {
  memcpy(dst, src, h->len);          //EXPECT UNVALIDATED_SIZE
}

// A guard on the same field validates it — clean.
int index_by_field_guarded(int *buf, int n, struct Hdr *h) {
  /* @mem demo::buf { free: free, owner: buf } */
  buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (h->idx < n) {
    r = buf[h->idx];                 // h->idx < n, buf holds n — covered
  }
  free(buf);
  return r;
}

// A length read from a field, bounded by the destination's fixed size — clean.
void copy_field_len_guarded(const char *src, struct Hdr *h) {
  if (h->len <= 64) {
    memcpy(dst, src, h->len);        // h->len <= 64 — covered
  }
}

// Re-tainting: a guard validates the field, then it is reassigned untrusted before use.
void revalidate_needed(const char *src, struct Hdr *h, int v) {
  if (h->len <= 64) {
    h->len = v;                      // reassigned to an untrusted value -> validation cleared
    memcpy(dst, src, h->len);        //EXPECT UNVALIDATED_SIZE
  }
}
