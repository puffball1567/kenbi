// An assignment from `new struct S` is an allocation like any other.
//
// For `p = new struct S` (an elaborated type name after `new`) libclang-14 reports no valid end
// for the new-expression, and so none for the assignment. The assignment's operator used to be
// read from the tokens of its whole extent, which then held nothing: the statement was not
// recognised as an assignment and was dropped, allocation and all — a leak reported nowhere.

struct S { int a; };

// @kenbi
void leak_elaborated() {
  /* @mem t::s { free: delete, owner: d } */
  struct S *d;
  d = new struct S;                  //EXPECT LEAK
  d->a = 0;
}

// @kenbi
void released_elaborated() {
  /* @mem t::s2 { free: delete, owner: e } */
  struct S *e;
  e = new struct S;
  e->a = 0;
  delete e;
}

// @kenbi
void double_release_elaborated() {
  /* @mem t::s3 { free: delete, owner: f } */
  struct S *f;
  f = new struct S;
  delete f;
  delete f;                          //EXPECT DOUBLE_FREE
}
