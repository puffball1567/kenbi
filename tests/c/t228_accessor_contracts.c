#include <stdlib.h>
// AN ACCESSOR CONTRACT IS A CONTRACT ON A SLOT, AND THE CALLEE HAS TO HONOUR IT.
//
// `@frees(*p)` (the `T**` out-parameter sink) and `@frees(p.f)` (a struct field) were visible at
// the CALLSITE only: the callee that actually writes the release had nothing to discharge, so
// the declared contract could not be verified there — `free(*p)` inside it read as an
// unaccounted release, and `@frees(*p)` on a function whose body does free it reported
// CONTRACT_NOT_HONORED.
//
// Both forms now seed the SLOT the contract names, keyed like any other field path
// (`<param>::*`, `<param>::f`), so the release inside the callee discharges the obligation and a
// body that does NOT release is the contract violation it is. The mirror also holds: a release
// through such a slot with NO contract is default-red, which for the field form used to produce
// no finding at all.

// @allocator t::heap { alloc: malloc, free: free }
struct box { char *f; };
// @borrows(p)
void use(const char *p);

// --- 1. the `T**` out-parameter sink ---------------------------------------------------------
// @kenbi
// @frees(*pp)
void destroy_out_direct(char **pp) {
  free(*pp);
}

// The same sink written through a local — the Juliet / real-C shape.
// @kenbi
// @frees(*pp)
void destroy_out_local(char **pp) {
  char *d = *pp;
  free(d);
}

// --- 2. the struct-field sink -----------------------------------------------------------------
// @kenbi
// @frees(p.f)
void destroy_field_direct(struct box *p) {
  free(p->f);
}

// @kenbi
// @frees(p.f)
void destroy_field_local(struct box *p) {
  char *d = p->f;
  free(d);
}

// --- 3. a declared accessor release the body does not perform ---------------------------------
// @kenbi
// @frees(*pp)
void promises_but_reads(char **pp) {   //EXPECT CONTRACT_NOT_HONORED
  use(*pp);
}

// --- 4. releasing the same slot twice ---------------------------------------------------------
// @kenbi
// @frees(*pp)
void releases_twice(char **pp) {
  char *d = *pp;
  free(d);
  free(*pp);   //EXPECT DOUBLE_FREE
}

// --- 5. no contract: every accessor release stays default-red ---------------------------------
// @kenbi
void no_contract_field(struct box *p) {
  free(p->f);   //EXPECT UNCONTRACTED_RELEASE
}

// @kenbi
void no_contract_field_local(struct box *p) {
  char *d = p->f;
  free(d);   //EXPECT UNCONTRACTED_RELEASE
}

// @kenbi
void no_contract_out(char **pp) {
  free(*pp);   //EXPECT UNCONTRACTED_RELEASE
}

// @kenbi
void no_contract_out_local(char **pp) {
  char *d = *pp;
  free(d);   //EXPECT UNCONTRACTED_RELEASE
}

// --- 6. the caller's side still transfers ------------------------------------------------------
// `sink(&data)` with `@frees(*pp)` releases `data` here: a second release is a double free.
// @kenbi
void caller_transfers(void) {
  /* @mem t::b { free: free, owner: data } */
  char *data = (char *)malloc(16);
  if (data == NULL) return;
  destroy_out_direct(&data);
  free(data);   //EXPECT DOUBLE_FREE
}

// --- 7. the slot survives a pointer copy / cast ------------------------------------------------
// `void *v` cast into `char **p` derefs to the same object, so the contract seeded on `*v`
// reaches the `free(*p)` the body actually writes.
// @kenbi
// @frees(*v)
void destroy_out_through_cast(void *v) {
  char **pp = (char **)v;
  char *d = *pp;
  free(d);
}
