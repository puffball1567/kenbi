#include <stdlib.h>
// EXCLUSIVE PARAMETERS. `@unique(p)` above a function declares that, during a call, nothing
// else the call is given reaches the object `p` points into — what C's `restrict` promises and
// no compiler checks. kenbi verifies it on both sides. At every call, the argument passed for
// `p` is compared with each other pointer argument: the same object is UNIQUE_ALIASED, and a
// pair nothing shows to be distinct is UNIQUE_UNPROVEN. Distinct variables, distinct members
// of one struct, separate allocations made in the calling function, a local whose address
// exists nowhere else, and a parameter the caller itself declares `@unique` are distinct. In
// the body, the pointer — or a copy of it — stored where it outlives the call is
// UNIQUE_ESCAPES.

struct Pair { int a; int b; };
struct Ctx { char *buf; char *tmp; };
char *g_saved;
char g_buf[16];

// @unique(dst)
// @borrows(dst)
void copy_into(char *dst, const char *src, unsigned n);

// the same pointer twice
// @kenbi
void same_pointer(char *p) {
  copy_into(p, p, 4);                             //EXPECT UNIQUE_ALIASED
}

// ... or an offset into the same object
// @kenbi
void offset_into_same(char *p) {
  copy_into(p, p + 4, 4);                         //EXPECT UNIQUE_ALIASED
}

// a struct and one of its own members
// @kenbi
void whole_and_member(void) {
  struct Pair s;
  copy_into((char *)&s, (const char *)&s.b, 4);   //EXPECT UNIQUE_ALIASED
}

// an interior pointer of the allocation passed beside it
// @kenbi
void allocation_and_interior(void) {
  /* @mem t::a { alloc: malloc, free: free, owner: b } */
  char *b = malloc(8);
  if (!b) return;
  char *row = b + 2;
  copy_into(b, row, 2);                           //EXPECT UNIQUE_ALIASED
  free(b);
}

// two parameters of a caller that declares nothing about them
// @kenbi
void two_parameters(char *p, const char *q) {
  copy_into(p, q, 4);                             //EXPECT UNIQUE_UNPROVEN
}

// a global beside a pointer that may point at it
// @kenbi
void global_and_parameter(const char *q) {
  copy_into(g_buf, q, 8);                         //EXPECT UNIQUE_UNPROVEN
}

// two pointers loaded from fields
// @kenbi
void two_fields(struct Ctx *c) {
  copy_into(c->buf, c->tmp, 4);                   //EXPECT UNIQUE_UNPROVEN
}

// distinct local arrays
// @kenbi
void two_locals(void) {
  char a[8];
  char b[8];
  copy_into(a, b, 8);
}

// distinct members of one struct, directly or through a pointer
// @kenbi
void two_members(struct Pair *s) {
  struct Pair t;
  copy_into((char *)&t.a, (const char *)&t.b, 4);
  copy_into((char *)&s->a, (const char *)&s->b, 4);
}

// the caller declares its own parameter exclusive: it cannot be the other parameter
// @kenbi
// @unique(p)
void caller_declares(char *p, const char *q) {
  copy_into(p, q, 4);
}

// a literal shares nothing
// @kenbi
void with_literal(char *p) {
  copy_into(p, "abcd", 4);
}

// a local cannot be what the function was handed
// @kenbi
void local_and_parameter(const char *q) {
  char a[8];
  copy_into(a, q, 8);
}

// ... nor can an allocation made here
// @kenbi
void allocation_and_parameter(const char *q) {
  /* @mem t::b { alloc: malloc, free: free, owner: b } */
  char *b = malloc(8);
  if (!b) return;
  copy_into(b, q, 8);
  free(b);
}

// the body keeps the pointer
// @kenbi
// @unique(p)
void keeps(char *p) {
  g_saved = p;                                    //EXPECT UNIQUE_ESCAPES
}

// ... or a copy derived from it
// @kenbi
// @unique(p)
void keeps_a_copy(char *p, struct Ctx *c) {
  char *q = p + 1;
  c->buf = q;                                     //EXPECT UNIQUE_ESCAPES
}

// local copies are fine
// @kenbi
// @unique(p)
void uses_locally(char *p) {
  char *q = p;
  *q = 0;
}
