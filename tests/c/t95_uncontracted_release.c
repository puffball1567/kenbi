#include <stdlib.h>
// Intake-side default-red: UNCONTRACTED_RELEASE. Freeing a pointer parameter the
// function never declared it owns — the cross-function "sink" shape Juliet splits
// across files (e.g. *_65b.c). Symmetric to UNCONTRACTED_ESCAPE on the call side.
// Each case shows a point on the resolution menu.

// (1) undeclared param freed -> RED (declare the intake, or it stays default-red)
void sink(char *p) {
  free(p);   //EXPECT UNCONTRACTED_RELEASE
}

// (2) @frees declared -> this function owns and releases p: the contract is honored,
//     no finding (and a second free across a call becomes a confident DOUBLE_FREE).
// @frees(p)
void owns_and_frees(char *p) {
  free(p);
}

// (3) @borrows declared but the body frees it -> BORROW_FREED (the owner frees it,
//     not the borrower). The intake contract turns a silent release into the right bug.
// @borrows(p)
void borrows_but_frees(char *p) {
  free(p);   //EXPECT BORROW_FREED
}

// (4) an undeclared param only read, never released -> clean: using / passing an
//     incoming pointer is fine; only releasing it without a contract is the boundary.
int reader(const char *p) {
  return p[0];
}
