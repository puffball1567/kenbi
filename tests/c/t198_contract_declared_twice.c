#include <stdlib.h>
// THE SAME CONTRACT DECLARED TWICE — on the prototype callers compile against and again on the
// definition (what including your own header gives you, and the recommended way to write it) —
// must seed the parameter ONCE. Seeding it twice created two obligations for one parameter, so
// the single `free(p)` discharged only one and the function was reported CONTRACT_NOT_HONORED
// for a contract it does honour.

// @frees(p)
void release_twice_declared(char *p);

// @frees(p)
void release_twice_declared(char *p) {
  free(p);
}

// ... and the contract still binds: a body that does NOT free is still caught
// @frees(q)
void forgets_to_free(char *q);

// @frees(q)
void forgets_to_free(char *q) {   //EXPECT CONTRACT_NOT_HONORED
  (void)q;
}

// a borrow declared twice likewise stays a borrow: freeing it is still a violation
// @borrows(b)
void borrow_twice_declared(char *b);

// @borrows(b)
void borrow_twice_declared(char *b) {
  free(b);   //EXPECT BORROW_FREED
}
