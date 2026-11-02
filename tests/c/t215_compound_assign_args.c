#include <stdlib.h>
// A CALL ON THE RIGHT OF A COMPOUND ASSIGNMENT STILL PASSES ITS ARGUMENTS. C accumulates a
// status flag while building a cache — `status &= AppendValueToLinkedList(cache, entry);` is how
// ImageMagick's log, coder, colour and magic registries are all built — and the arguments of a
// call in that position were not lowered at all. So the hand-off went unreported (kenbi never
// asked what the container does with the object) and the pointer looked abandoned: a false LEAK,
// at the allocation, for memory that had just been given away. The plain-statement and
// simple-assignment forms of the same call were handled; only this one was not.

int append(void *cache, void *value);
// @borrows(p)
void use(int *p);

// the call's result feeds a compound assignment: the argument still crosses the boundary
static int via_compound(void *cache, int n) {
  int status = 1;
  /* @mem t::a { free: free, owner: p } */
  int *p = (int *) malloc(n * sizeof(int));
  status &= (int) append(cache, p);   //EXPECT UNCONTRACTED_ESCAPE
  return status;
}

// the same call as a bare statement
static int via_plain(void *cache, int n) {
  /* @mem t::b { free: free, owner: q } */
  int *q = (int *) malloc(n * sizeof(int));
  (void) append(cache, q);   //EXPECT UNCONTRACTED_ESCAPE
  return 1;
}

// ...and as a simple assignment
static int via_assign(void *cache, int n) {
  /* @mem t::c { free: free, owner: r } */
  int *r = (int *) malloc(n * sizeof(int));
  const int status = append(cache, r);   //EXPECT UNCONTRACTED_ESCAPE
  return status;
}

// a compound assignment that is just arithmetic still behaves: the pointer advance makes an
// interior pointer, releasing that is the finding it always was, and the owner it advanced away
// from is then never released — so the allocation leaks too
static void advances(int n) {
  /* @mem t::d { free: free, owner: s } */
  int *s = (int *) malloc(n * sizeof(int));   //EXPECT LEAK
  use(s);
  s += 2;
  free(s);   //EXPECT FREE_INTERIOR
}
