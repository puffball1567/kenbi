#include <stdlib.h>
// ADVISORY PROMOTION (#B): storing an owned pointer into a location kenbi cannot follow — a raw
// `*out` out-parameter or an `arr[i]` slot — used to defer to an advisory. kenbi no longer assumes
// some other owner will free it (declare-don't-infer / default-red): the hand-off is unverifiable,
// so it is an error. `@escapes` on the line DECLARES an intentional hand-off out of kenbi's view
// (to external code / a system boundary) and clears it — a narrow declaration, not a blanket
// `@unsafe`. See also the field-store form, which #2a/#2b track precisely (b->buf).

// RED: ownership escapes through an out-parameter kenbi cannot follow.
void out_param(char **out, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  *out = p;                //EXPECT ESCAPE_UNCHECKED
}

// RED: ownership escapes into an array slot.
void into_array(char **arr, int i, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  arr[i] = p;              //EXPECT ESCAPE_UNCHECKED
}

// GREEN: the hand-off is declared — an external owner takes it from here.
void declared_handoff(char **out, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  *out = p;  // @escapes
}
