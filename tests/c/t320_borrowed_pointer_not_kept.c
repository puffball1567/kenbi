#include <stdlib.h>
#include <string.h>
// A BORROWED POINTER IS GIVEN BACK. `@borrows(p)` and `@unique(p)` both promise that nothing
// holds the pointer once the call has returned, and the body is checked for the two ways it
// could: storing it (in a global, a field, or through another pointer), and passing it to a
// function that may. A pointer the function may not keep can be passed on only where the
// receiving parameter makes the same promise — `@borrows` or `@unique`, verified in that
// function's body in turn, so the chain holds however deep it goes — or to a function known
// to only read or release it. BORROW_ESCAPES / UNIQUE_ESCAPES otherwise.

struct Holder { const char *name; };
const char *g_name;

// @borrows(s)
void reads(const char *s);
// @unique(dst)
void fills(char *dst, unsigned n);
// @moves(s)
void takes(char *s);
void undeclared(const char *s);

// stored in a global
// @kenbi
// @borrows(s)
void stores_in_global(const char *s) {
  g_name = s;                                     //EXPECT BORROW_ESCAPES
}

// ... in a field of an object the caller keeps
// @kenbi
// @borrows(s)
void stores_in_field(struct Holder *h, const char *s) {
  h->name = s;                                    //EXPECT BORROW_ESCAPES
}

// ... or a copy of it, through another pointer
// @kenbi
// @borrows(s)
void stores_a_copy(const char **out, const char *s) {
  const char *t = s + 1;
  *out = t;                                       //EXPECT BORROW_ESCAPES
}

// passed to a function that says nothing about keeping it
// @kenbi
// @borrows(s)
void passes_to_undeclared(const char *s) {
  undeclared(s);                                  //EXPECT BORROW_ESCAPES
}

// ... the same for an exclusive pointer
// @kenbi
// @unique(p)
void unique_to_undeclared(char *p) {
  undeclared(p);                                  //EXPECT UNIQUE_ESCAPES
}

// ... and for one handed to a function declared to take it
// @kenbi
// @unique(p)
void unique_to_taker(char *p) {
  takes(p);                                       //EXPECT UNCONTRACTED_MOVE UNIQUE_ESCAPES
}

// through a function pointer nothing is declared about
// @kenbi
// @borrows(s)
void passes_through_pointer(void (*cb)(const char *), const char *s) {
  cb(s);                                          //EXPECT BORROW_ESCAPES
}

// lent on to another borrower, a copy included
// @kenbi
// @borrows(s)
void lends_on(const char *s) {
  const char *t = s;
  reads(s);
  reads(t + 1);
}

// an exclusive pointer lent to a borrower, and to another exclusive parameter
// @kenbi
// @unique(p)
void unique_lends_on(char *p) {
  reads(p);
  fills(p, 4);
}

// the C library's readers and writers give it back
// @kenbi
// @borrows(s)
unsigned uses_libc(char *dst, const char *s) {
  memcpy(dst, s, 4);
  return (unsigned)strlen(s);
}

// kept in locals only
// @kenbi
// @borrows(s)
char reads_locally(const char *s) {
  const char *t = s;
  return t[0];
}
