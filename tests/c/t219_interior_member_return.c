#include <stdlib.h>
// THE ADDRESS OF A MEMBER IS A HANDLE TO THE OBJECT — and whose object it is decides everything.
//
// C hands out a pointer to a struct's first member as the public view of a larger private one:
// ImageMagick returns `&root->root` (an `XMLTreeInfo *`) for a heap `XMLTreeRoot`, GTK does it
// for every GObject, and the caller releases the whole block through that pointer. kenbi read
// `return &b->member` as returning nothing at all, so the allocation looked abandoned at the
// return: two false LEAKs per such factory, one for the block and one for every field it owns.
//
// The mirror case was silent for the opposite reason: `&local.field` is the address of part of
// a STACK object, which is exactly as dangling as `&local`, and only the bare `&local` form was
// recognised.

struct Inner { int x; };
struct Outer { struct Inner inner; char *buf; };

// --- 1. a heap block handed out through the address of its member --------------------------
// @kenbi
// @owns
struct Inner *make(void) {
  /* @mem t::o { free: free, owner: o } */
  struct Outer *o = (struct Outer *) malloc(sizeof(*o));
  o->buf = (char *) malloc(8);
  return &o->inner;   /* the caller holds a pointer into the block: a transfer, not a leak */
}

// --- 2. ...but only when the base really is that heap block ---------------------------------
// A local with no such transfer still leaks.
// @kenbi
struct Inner *forgets(int n) {
  /* @mem t::p { free: free, owner: p } */
  struct Outer *p = (struct Outer *) malloc(sizeof(*p));   //EXPECT LEAK
  if (n > 0)
    return (struct Inner *) 0;
  return (struct Inner *) 0;
}

// --- 3. the address of part of a STACK object is dangling ------------------------------------
struct Pair { int a; int b; };

// @kenbi
int *member_of_local(void) {
  struct Pair s;
  s.a = 1;
  return &s.b;   //EXPECT DANGLING_RETURN
}

// @kenbi
int *element_of_local_array(void) {
  int arr[4];
  arr[0] = 1;
  return &arr[2];   //EXPECT DANGLING_RETURN
}

// --- 4. `&p->field` where p is a local POINTER is NOT this frame's storage -------------------
// @kenbi
// @owns
char **slot_of_heap(void) {
  /* @mem t::q { free: free, owner: q } */
  struct Outer *q = (struct Outer *) malloc(sizeof(*q));
  q->buf = (char *) 0;
  return &q->buf;
}
