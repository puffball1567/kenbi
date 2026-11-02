#include <stdlib.h>
// A FUNCTION THAT RETURNS WHAT IT FREED hands out a dangling pointer: the bug is reported in
// that function (DANGLING_RETURN); at its callers, with no return contract declared, the result
// is a maybe-freed handle — a use is POSSIBLE_USE_AFTER_FREE, a free POSSIBLE_DOUBLE_FREE,
// never a leak (the Juliet `return_freed_ptr` shape). Declaring `@owns` on such a function
// would be a lie; a factory that does NOT free its result keeps the ordinary owned result.

// @borrows(s)
void use(char *s);

static char *make_dangling(int n) {
  /* @mem t::a { free: free, owner: p } */
  char *p = malloc(n);
  free(p);
  return p;   //EXPECT DANGLING_RETURN
}

// @owns
static char *make_owned(int n) {
  /* @mem t::b { free: free, owner: p } */
  char *p = malloc(n);
  return p;
}

static void use_dangling(void) {
  char *q = make_dangling(8);
  use(q);   //EXPECT POSSIBLE_USE_AFTER_FREE
}

static void free_dangling(void) {
  char *q = make_dangling(8);
  free(q);   //EXPECT POSSIBLE_DOUBLE_FREE
}

static void owned_ok(void) {
  /* @mem t::c { free: free, owner: q } */
  char *q = make_owned(8);
  use(q);
  free(q);
}

// ... but the assign-back idiom is NOT handing out a dangling pointer: the release gave the
// variable its own return value (NULL by the usual convention) before it left, and callers
// check for it. Treating this as a dangling result made every later use of the result a
// POSSIBLE_USE_AFTER_FREE — 277 of them in one ImageMagick file alone.
// @allocator t::m { alloc: m_alloc, free_returns_null: m_free }
void *m_alloc(int n);
void *m_free(void *p);

// @owns
static char *make_or_null(int n) {
  char *p = m_alloc(n);
  if (n < 0)
    p = (char *) m_free(p);
  return p;
}

static void use_maybe_null(void) {
  /* @mem t::r { free: m_free, owner: q } */
  char *q = make_or_null(8);
  use(q);
  q = (char *) m_free(q);
}
