// @spatial
// SPATIAL size sink: an untrusted length argument to a buffer write (memcpy / memset /
// strncpy / recv / …) with no bound check present is UNVALIDATED_SIZE — the classic
// buffer overflow (CWE-120 / CWE-787). A present bound (here `len <= 64`) clears it.
#include <string.h>

extern char dstbuf[64];

void copy_unbounded(const char *src, int len) {
  memcpy(dstbuf, src, len);          //EXPECT UNVALIDATED_SIZE
}

void copy_bounded(const char *src, size_t len) {
  if (len <= 64) {
    memcpy(dstbuf, src, len);        // bounded on this path — clean
  }
}
