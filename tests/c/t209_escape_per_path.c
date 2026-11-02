#include <stdlib.h>
// AN ESCAPE ON ONE BRANCH IS NOT AN ESCAPE ON THE OTHER. When ownership leaves kenbi's view —
// stored through a pointer it cannot follow, handed to an uncontracted callee — the escape is
// reported and the origin is no longer called a leak: someone else may own it now. That fact
// was held for the whole function, so a branch that escaped the pointer silenced the leak on
// every OTHER branch, including ones the escape cannot reach. `if (c) { *out = p; return; }`
// followed by a fall-through that simply drops `p` came back GREEN — a false GREEN, the class
// this checker exists to refuse. The fact is now a per-path state, like freed and moved.

// @borrows(s)
void use(char *s);
void sink(char *s);

// stored through a pointer kenbi cannot follow
static void escape_through_pointer(int c, char **out) {
  /* @mem t::a { free: free, owner: p } */
  char *p = malloc(8);   //EXPECT LEAK
  if (c) {
    *out = p;   //EXPECT ESCAPE_UNCHECKED
    return;
  }
  use(p);
}

// stored into an array element kenbi cannot follow
static void escape_into_array(int c, char **arr, int i) {
  /* @mem t::b { free: free, owner: q } */
  char *q = malloc(8);   //EXPECT LEAK
  if (c) {
    arr[i] = q;   //EXPECT ESCAPE_UNCHECKED
    return;
  }
  use(q);
}

// handed to an uncontracted callee
static void escape_to_callee(int c) {
  /* @mem t::c { free: free, owner: r } */
  char *r = malloc(8);   //EXPECT LEAK
  if (c) {
    sink(r);   //EXPECT UNCONTRACTED_ESCAPE
    return;
  }
  use(r);
}

// ...and the escaping path itself is still not a leak: the escape was the finding there
static void escapes_on_every_path(char **out) {
  /* @mem t::d { free: free, owner: s } */
  char *s = malloc(8);
  *out = s;   //EXPECT ESCAPE_UNCHECKED
}
