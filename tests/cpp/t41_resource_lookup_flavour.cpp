#include <cstdlib>
// WHICH DECLARED RESOURCE AN ALLOCATION BELONGS TO IS NOT A FREE GUESS.
//
// `@mem` is resolved to an allocation by owner name and — because one declaration usually stands
// for a resource KIND while several locals hold objects of that kind — by falling back to the
// nearest declaration above when no name matches. That fallback is a guess about identity, and
// an unchecked guess produced a verdict about something it had never seen: an object created
// with `new` beside an unrelated `@mem { free: free, … }` took on THAT resource, and `delete` on
// it read as WRONG_DEALLOCATOR against a resource it has nothing to do with.
//
// The guess is now held to the one thing the site does state — the allocation FLAVOUR. A `new`
// cannot belong to a resource released by `free`, nor a `malloc` to one released by `delete`.
// What nothing names at all is UNKNOWN_RESOURCE: declare it.
//
// The cases are ordered so that each one's fallback candidates are only the declarations above
// it, which is what the resolution rule looks at.

struct Base {
  virtual void action(char *) {}
  virtual ~Base() {}
};

// @borrows(p)
// @nothrow
void use(char *p);

// --- 1. a malloc local does not take a `delete` resource --------------------------------------
// @kenbi
void malloc_beside_a_delete_resource() {
  /* @mem t::chars { free: delete, owner: data } */
  char *data = new char[8];
  char *other = (char *)malloc(8);   //EXPECT UNKNOWN_RESOURCE
  use(other);
  free(other);
  delete[] data;
}

// --- 2. the fallback still works WITHIN a flavour ----------------------------------------------
// A second `new char[]` local belongs to the `delete`-released resource declared above it: one
// declaration, several handles of the same kind. Were it not resolved, `fresh` would be an
// undeclared resource and its release unaccounted.
// @kenbi
void second_handle_of_the_same_kind() {
  char *data = new char[8];
  delete[] data;
  char *fresh = new char[8];
  delete[] fresh;
}

// --- 3. a `new` object beside a malloc resource is not that resource ---------------------------
// The assertion is the SILENCE on the `delete`: with the flavour check the object cannot take
// `t::buf`'s identity, so its release is never measured against that resource's `free:`. (It
// resolves to the `delete`-released `t::chars` declared in case 1 — the nearest candidate of its
// own flavour — which is the fallback working as intended.) Without the check this line was
// WRONG_DEALLOCATOR against a resource the object has nothing to do with.
// @kenbi
void new_object_beside_a_malloc_resource() {
  Base *obj = new Base;
  /* @mem t::buf { free: free, owner: data } */
  char *data = (char *)calloc(100, 1);
  use(data);
  free(data);
  delete obj;
}

// --- 4. an owner named by its FIELD path still resolves ----------------------------------------
// `@mem { owner: buf }` above `b->buf = malloc(…)`: the declaration names the field, the site
// spells the path.
struct box { char *buf; };
// @kenbi
// @borrows(b)
void field_owner_resolves(box *b, int n) {
  /* @mem t::fbuf { free: free, owner: buf } */
  b->buf = (char *)malloc(n);
  free(b->buf);
}
