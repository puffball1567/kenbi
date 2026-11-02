#include <stdlib.h>
// THE OUT-PARAMETER SOURCE. `source(&data)` allocates INTO the caller's variable through a `T**`
// (the Juliet 4x / 6x channel). `@owns(*p)` on the source declares it: at the callsite the
// argument variable becomes an owned origin (declare the resource with @mem above the call);
// in the source's body the store through the pointee is the declared hand-out, not a leak.

// @owns(*p)
void make_buf(char **p);           // cross-file source: the prototype carries the contract

// @owns(*p)
static void make_local(char **p) { // in-file source: the store is the declared hand-out
  /* @mem t::in { free: free, owner: q } */
  char *q = malloc(8);
  *p = q;
}

// @borrows(s)
void use(char *s);

// the caller receives ownership and never releases it
static void leak_via_out(void) {
  char *data;
  /* @mem t::buf { free: free, owner: data } */
  make_buf(&data);   //EXPECT LEAK
  use(data);
}

// ... releases it once -> clean
static void ok_via_out(void) {
  char *data;
  /* @mem t::buf2 { free: free, owner: data } */
  make_buf(&data);
  free(data);
}

// ... releases it twice
static void double_via_out(void) {
  char *data;
  /* @mem t::buf3 { free: free, owner: data } */
  make_local(&data);
  free(data);
  free(data);   //EXPECT DOUBLE_FREE
}
