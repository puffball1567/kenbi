#include <stdlib.h>
#include "ext.h"
#include "lib.h"

/* no `@kenbi` marker above it: the body is here, kenbi did not check it -> `unchecked` */
// @frees(p)
void ext_take(char *p) {
  free(p);
}

/* under `@kenbi`, and the body CONTRADICTS its contract — it never releases p.
   Published as `red`: the contract exists, and relying on it would be a mistake. */
// @kenbi
// @frees(p)
void ext_bad(char *p) {
  (void) p;
}

/* under `@kenbi` and clean, but it discharges the obligation through a boundary no file here
   defines. GREEN — the boundary is declared — with trust residue, so `green`, never
   `verified`. */
// @kenbi
// @frees(p)
void ext_trusting(char *p) {
  vendor_release(p);
}
