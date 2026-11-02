#include <cstdlib>
// THE REFERENCE OUT-PARAMETER SOURCE (C++). `source(data)` with `char *&data` allocates INTO the
// caller's variable. `@owns(data)` on the source declares it: at the callsite the argument
// variable becomes an owned origin (declare the resource with @mem above the call); in the
// source's body the assignment to the parameter is the declared hand-out, not a leak.

// @owns(data)
static void source(char *&data) {
  /* @mem t::src { free: free, owner: data } */
  data = (char *)malloc(100);
}

// @borrows(s)
void use(char *s) noexcept;

// the caller receives ownership and never releases it
static void leak_via_ref() {
  char *data = nullptr;
  /* @mem t::buf { free: free, owner: data } */
  source(data);   //EXPECT LEAK
  use(data);
}

// ... releases it once -> clean
static void ok_via_ref() {
  char *data = nullptr;
  /* @mem t::buf2 { free: free, owner: data } */
  source(data);
  free(data);
}

// ... uses it after releasing
static void uaf_via_ref() {
  char *data = nullptr;
  /* @mem t::buf3 { free: free, owner: data } */
  source(data);
  free(data);
  use(data);   //EXPECT USE_AFTER_FREE
}

// a source that allocates into the reference AND frees it before returning (`@frees` too):
// the caller receives a dangling pointer
// @frees(data)
// @owns(data)
static void source_and_free(char *&data) {
  /* @mem t::sf { free: free, owner: data } */
  data = (char *)malloc(100);
  free(data);
}

static void dangling_via_ref() {
  char *data = nullptr;
  /* @mem t::buf4 { free: free, owner: data } */
  source_and_free(data);
  use(data);   //EXPECT USE_AFTER_FREE
}
