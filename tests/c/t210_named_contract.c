#include <stdlib.h>
// A CONTRACT DECLARED BY NAME. The inline forms (`@frees(p)` above the declaration) cannot
// reach a project you may not edit: there is nowhere to put the comment. `@contract <Fn> { … }`
// names the function instead, so it can live in a force-included, comment-only overlay header
// next to `@allocator` and `@list`. It is the same contract, resolved through the same binding:
// a `frees:` still carries the body obligation, a `borrows:` still makes freeing the parameter
// a bug, and a declaration that does not hold is contradicted rather than believed.
//
// Parameters may be named by POSITION (`$1`, 1-based), because C headers are more often than
// not written with unnamed parameters — and the call sites that need the contract are in the
// files that see only that prototype.

// @contract release_named { frees: p }
// @contract release_pos   { frees: $1 }
// @contract look_at       { borrows: $1 }
// @contract forgets       { frees: $1 }
// @contract frees_borrow  { borrows: $1 }
// @contract missing_param { frees: nosuchparam }
// @contract make_it       { owns }

void release_named(char *p);
void release_pos(char *);
void look_at(char *);

// the contract binds at the call sites: one release, one read, no finding
static void honoured(void) {
  /* @mem t::a { free: free, owner: q } */
  char *q = malloc(8);
  look_at(q);
  release_named(q);
}

// ...by position too
static void honoured_by_position(void) {
  /* @mem t::b { free: free, owner: q } */
  char *q = malloc(8);
  release_pos(q);
}

// a second release through the declared releaser is a double free
static void released_twice(void) {
  /* @mem t::c { free: free, owner: q } */
  char *q = malloc(8);
  release_pos(q);
  release_pos(q);   //EXPECT DOUBLE_FREE
}

// a read after it is a use after free
static void read_after_release(void) {
  /* @mem t::d { free: free, owner: q } */
  char *q = malloc(8);
  release_pos(q);
  look_at(q);   //EXPECT USE_AFTER_FREE
}

// a borrow declaration does NOT hand ownership over: the pointer is still owed here
static void borrow_is_not_a_transfer(void) {
  /* @mem t::e { free: free, owner: q } */
  char *q = malloc(8);   //EXPECT LEAK
  look_at(q);
}

// `owns` on its own is a RETURN contract, even when the prototype's parameters are unnamed —
// the normal style in a C header. An empty parameter name used to match the unnamed parameter
// and bind an out-parameter contract instead, dropping the return contract: the factory's
// result was not owned and its leak went unreported.
char *make_it(int);
static void factory_result_is_owed(void) {
  /* @mem t::f { free: free, owner: q } */
  char *q = make_it(8);   //EXPECT LEAK
  look_at(q);
}

// THE DECLARATION IS CHECKED, NOT TRUSTED. A body declared to free its parameter and not
// freeing it is caught, exactly as with the inline form.
void forgets(char *p) {   //EXPECT CONTRACT_NOT_HONORED
  (void)p;
}

// ...and a body that frees what it declared it only borrows is caught too
void frees_borrow(char *p) {
  free(p);   //EXPECT BORROW_FREED
}

// a contract naming a parameter the function does not have binds nothing, so the boundary it
// was meant to declare stays uncontracted — the safe direction. An advisory says why, carried
// on no particular line (the declaration lives in another file).
//EXPECT CONTRACT_UNBOUND@0
void missing_param(char *p);
static void boundary_stays_red(void) {
  /* @mem t::g { free: free, owner: q } */
  char *q = malloc(8);
  missing_param(q);   //EXPECT UNCONTRACTED_ESCAPE
  free(q);
}
