#include <stdlib.h>
// DEREFERENCING A POINTER KENBI KNOWS IS NULL IS THE BUG, NOT A RISK. The null state has three
// values, and only the middle one was reported: a POSSIBLY-null pointer drew `NULL_DEREF`, a
// pointer known NON-null drew nothing (correctly), and a pointer known NULL drew nothing
// either — the two idioms that produce that knowledge are the defensive `free(p); p = NULL;`
// and a release declared to hand back NULL, both of which are everywhere in C.
//
// The silence also made the fact unusable: recording "this branch knows p is null" would have
// turned a definite dereference into no finding at all, so branches a null test rules out
// cannot be pruned until this is reported.

// @allocator t::m { alloc: Acquire, free_returns_null: Relinquish }
void *Acquire(int n);
void *Relinquish(void *p);
// @borrows(p)
void use(int *p);

// the defensive idiom, then a read through the nulled handle
static void nulled_then_read(int n) {
  /* @mem t::a { free: free, owner: p } */
  int *p = (int *) malloc(n * sizeof(int));
  use(p);
  free(p);
  p = NULL;
  *p = 1;   //EXPECT NULL_DEREF
}

// a release DECLARED to return NULL leaves the handle null
static void release_returns_null(int n) {
  int *q = (int *) Acquire(n);
  q = (int *) Relinquish(q);
  *q = 1;   //EXPECT NULL_DEREF
}

// ...and the idiom itself stays clean: nulling a released pointer is not a finding, and
// releasing a null one is the defined no-op
static void the_idiom_is_fine(int n) {
  /* @mem t::b { free: free, owner: r } */
  int *r = (int *) malloc(n * sizeof(int));
  use(r);
  free(r);
  r = NULL;
  free(r);
}
