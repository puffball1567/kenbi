// A statement that is an operator expression other than an assignment used to be dropped, and an
// allocation or a release inside it with it: `free(p), free(p);` reported no double free, and
// `q = malloc(4), x = 1;` no leak. A comma is now lowered as the sequence it is, left to right;
// any other operator holding a memory operation is refused (UNSUPPORTED_CONSTRUCT).
// After a refusal nothing held so far is asserted about: the construct may have released it, so
// the allocation in comparison_holding_a_release is not reported as a leak.
#include <stdlib.h>

// @kenbi
void comma_of_releases(void) {
  /* @mem t::a { free: free, owner: p } */
  char *p = malloc(4);
  free(p), free(p);                  //EXPECT DOUBLE_FREE
}

// @kenbi
void comma_holding_an_allocation(void) {
  /* @mem t::b { free: free, owner: q } */
  char *q;
  int x = 0;
  q = malloc(4), x = 1;              //EXPECT LEAK
  (void)x;
}

// @kenbi
void comparison_holding_a_release(void) {
  /* @mem t::d { free: free, owner: s } */
  char *s = malloc(4);
  int x = 0;
  x == (free(s), 0);                 //EXPECT UNSUPPORTED_CONSTRUCT
}

// @kenbi
void comma_without_memory_ops(void) {
  /* @mem t::c { free: free, owner: r } */
  char *r = malloc(4);
  int x = 0, y = 0;
  x = 1, y = 2;
  (void)x; (void)y;
  free(r);
}
