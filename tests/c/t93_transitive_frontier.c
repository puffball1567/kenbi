#include <stdlib.h>
// Transitive trusted frontier: handler -> service (both covered, @borrows) -> store
// (declared @borrows but NOT covered). handler & service are each GREEN, but the
// contracted closure REACHES `store`, whose body kenbi never verified. So the
// residue propagates: `store` is the frontier, and neither handler nor service is
// verified even though both are GREEN. Demonstrates that verification is transitive
// over the contracted call graph, not just one level deep.
//COV green=2 verified=0 adopted=2 totalMem=2 frontier=store
// One flow rooted at handler (service is called by handler, so not an entry); it is
// blocked transitively by store.
//COV flows=1 flow=handler/false/store

// @borrows(buf)
void store(char *buf);

// @kenbi
// @borrows(buf)
void service(char *buf) {
  store(buf);   // borrowed buf forwarded through another @borrows boundary
}

// @kenbi
void handler(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  service(p);
  free(p);
}
