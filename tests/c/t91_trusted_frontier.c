#include <stdlib.h>
// Trusted frontier: `handler` is covered and
// GREEN, but its GREEN rests on `consume`'s declared @borrows contract — and
// `consume` is not itself covered. So handler is GREEN (contracted / modular-trust)
// but NOT verified; `consume` is the trusted frontier ("cover this to remove the
// residue"). No diagnostic fires — coverage, not a finding, carries the honesty.
//COV green=1 verified=0 adopted=1 totalMem=1 frontier=consume
//COV flows=1 flow=handler/false/consume

// @borrows(buf)
void consume(char *buf);

// @kenbi
void handler(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  consume(p);   // declared borrow -> contracted boundary, handler stays GREEN
  free(p);
}
