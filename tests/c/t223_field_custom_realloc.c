#include <stdlib.h>
// A PROJECT'S OWN RESIZE IS A REALLOC. `@allocator … { realloc: Resize }` declares it, and the
// plain-variable path has always treated `p = Resize(p,…)` exactly as `p = realloc(p,…)`: the
// obligation CONTINUES (the same block, grown), and the self-assignment is
// REALLOC_SELF_REASSIGN because on OOM the NULL result overwrites the only handle.
//
// The FIELD path checked the builtin's NAME instead of the declared family, so
// `b->f = Resize(b->f,…)` lowered as a FRESH allocation into a field that already owned
// something, and the overwrite rule called growing the buffer a leak of the old one. Every
// hand-rolled grow-in-place on a struct field read that way; MagickCore's xml-tree.c grows its
// attribute and processing-instruction tables exactly like this.

// @allocator t::fam { alloc: acq, realloc: resz, free_returns_null: rel }
void *acq(unsigned long n, unsigned long s);
void *resz(void *p, unsigned long n, unsigned long s);
void *rel(void *p);
typedef struct { char *f; } Box;

// RED, but for the RIGHT reason — and at the RIGHT line. The growth is not a leak of the buffer
// it grows; what it is, is a self-assignment that loses the only handle if the resize fails.
// @kenbi
void build_then_grow(Box *b, int n) {
  b->f = (char *) acq(16, 1);
  b->f = (char *) resz(b->f, n, 1);   //EXPECT REALLOC_SELF_REASSIGN
  b->f = (char *) rel(b->f);
}

// A self-reassigning resize is unconditionally broken — `@realloc` vouches the FRESH-dest form,
// not this one — so only `@unsafe` silences it, and then the block is still verified to be
// released exactly once.
// @kenbi
void build_then_grow_vouched(Box *b, int n) {
  b->f = (char *) acq(16, 1);
  b->f = (char *) resz(b->f, n, 1);   // @unsafe
  b->f = (char *) rel(b->f);
}

// the plain-variable twin, which has always behaved this way — the two now agree.
// @kenbi
void build_then_grow_var(int n) {
  /* @mem t::v { free: rel, owner: p } */
  char *p = (char *) acq(16, 1);
  p = (char *) resz(p, n, 1);   //EXPECT REALLOC_SELF_REASSIGN
  p = (char *) rel(p);
}

// RED: resizing something ELSE into the field is a fresh value, not a continuation — the field's
// own buffer is orphaned by the store.
// @kenbi
void replace_field(Box *b, char *other, int n) {
  b->f = (char *) acq(16, 1);   //EXPECT LEAK
  b->f = (char *) resz(other, n, 1);
  b->f = (char *) rel(b->f);
}
