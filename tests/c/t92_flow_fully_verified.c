// @kenbi
#include <stdlib.h>
// Fully verified flow: a file-level @kenbi covers every function. `handler` hands
// its buffer to `consume`, which declares @borrows AND whose body is covered + clean
// (it only reads, never frees -> honours the contract). The contracted closure is
// fully covered, so there is no trusted residue: both functions are verified and the
// frontier is empty (verified == green).
//COV green=2 verified=2 adopted=2 totalMem=2 frontier=-
//COV flows=1 flow=handler/true/-

// @borrows(buf)
void consume(char *buf) {
  (void)buf;            /* reads only; never frees -> honours @borrows */
}

void handler(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  consume(p);
  free(p);
}
