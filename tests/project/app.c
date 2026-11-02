#include "lib.h"

// the whole flow is declared: `lib_make` hands ownership over, `lib_release` takes it back.
// Analysed alone this is GREEN but rests on two unverified bodies; analysed with lib.c the
// closure closes and it is VERIFIED.
// @kenbi
void app(void) {
  /* @mem app::buf { free: free, owner: b } */
  char *b = lib_make(8);
  lib_release(b);
}

// ... this one hands the buffer to a library kenbi never sees: GREEN, but the frontier keeps
// `vendor_release` forever — no file in the project defines it.
// @kenbi
void app_vendor(void) {
  /* @mem app::vbuf { free: free, owner: b } */
  char *b = lib_make(8);
  vendor_release(b);
}
