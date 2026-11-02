// @spatial
// A bound check must be PRESENT and APPROPRIATE: it has to actually cover the buffer.
// A present-but-too-loose check (here bounding a 64-byte buffer by 1000) does not stop
// the overflow, so it is INAPPROPRIATE_BOUND — not GREEN. (Contrast t112 / t113, where
// the bound matches the buffer size and the access is clean.)
#include <string.h>

extern char buf64[64];
extern int arr256[256];

void oversized_size(const char *src, int len) {
  if (len <= 1000) {
    memcpy(buf64, src, len);     //EXPECT INAPPROPRIATE_BOUND
  }
}

void oversized_index(int idx) {
  if (idx < 1000) {
    arr256[idx] = 0;             //EXPECT INAPPROPRIATE_BOUND
  }
}
