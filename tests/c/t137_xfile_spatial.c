// @spatial
// CROSS-FILE spatial contracts: @counted_by / @invariant are declared on the prototypes in
// t137_xfile_spatial.h; this implementation (a different translation unit) inherits them by
// function name, resolved against ITS params — so the bounds verify across the file boundary.
#include "t137_xfile_spatial.h"

// GREEN: i < len <= cap (the cross-file invariant chain), data sized cap — covered.
int vec137_get(const Vec137 *v, unsigned int i, int *out) {
  if (i < v->len) {
    *out = v->data[i];
    return 1;
  }
  return 0;
}

// RED: the contract reached the impl (data IS sized cap), but i is unbounded — the access is
// still default-red, proving cross-file binding does not disable the check.
int vec137_unchecked(const Vec137 *v, unsigned int i, int *out) {
  *out = v->data[i];                 //EXPECT UNVALIDATED_INDEX
  return 1;
}
