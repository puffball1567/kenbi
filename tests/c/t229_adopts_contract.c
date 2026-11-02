#include <stdlib.h>
// A CONTAINER TAKES THE ELEMENT WITHOUT INVALIDATING IT.
//
// `AppendToList(list, value)` hands the release obligation to the collection: the list frees the
// element when it is destroyed, so the caller no longer owes it — but the element itself is not
// invalidated by being put in a list, and reading it afterwards is ordinary C. No existing
// contract says both halves of that:
//
//   `@frees(v)`   — the callee releases it, so a later read is USE_AFTER_FREE. Wrong.
//   `@moves(v)`   — the handle is dead, so a later read is USE_AFTER_MOVE. Wrong.
//   `@borrows(v)` — the caller still owes the release, so the value LEAKs here. Wrong.
//
// `@adopts(v)` is the missing word: the obligation moves to the callee, the object stays valid.
// The caller may read it and pass it on; releasing it here is a double free (the container will
// release it too); it is not a leak at exit.

// @allocator t::heap { alloc: malloc, free: free }
struct elem { char *name; int n; };
struct list;

// @adopts(value)
int AppendToList(struct list *l, struct elem *value);
// @borrows(p)
void use(const struct elem *p);
// @borrows(l)
struct list *ListOf(void);

// --- 1. the hand-off accounts for the element: not a leak ------------------------------------
// @kenbi
void handed_to_the_container(struct list *l) {
  /* @mem t::e { free: free, owner: e } */
  struct elem *e = (struct elem *)malloc(sizeof(*e));
  if (e == NULL) return;
  e->n = 1;
  (void)AppendToList(l, e);
}

// --- 2. …and the element is still readable afterwards ----------------------------------------
// This is the half `@moves` gets wrong: putting a pointer in a list does not invalidate it.
// @kenbi
void read_after_the_hand_off(struct list *l) {
  /* @mem t::e { free: free, owner: e } */
  struct elem *e = (struct elem *)malloc(sizeof(*e));
  if (e == NULL) return;
  (void)AppendToList(l, e);
  use(e);
  e->n = 2;
}

// --- 3. releasing it in the caller is now a double free ---------------------------------------
// @kenbi
void released_after_the_hand_off(struct list *l) {
  /* @mem t::e { free: free, owner: e } */
  struct elem *e = (struct elem *)malloc(sizeof(*e));
  if (e == NULL) return;
  (void)AppendToList(l, e);
  free(e);   //EXPECT DOUBLE_FREE
}

// --- 4. handing the same element to two containers ---------------------------------------------
// @kenbi
void handed_to_two_containers(struct list *a, struct list *b) {
  /* @mem t::e { free: free, owner: e } */
  struct elem *e = (struct elem *)malloc(sizeof(*e));
  if (e == NULL) return;
  (void)AppendToList(a, e);
  (void)AppendToList(b, e);   //EXPECT DOUBLE_FREE
}

// --- 5. the element's own fields go with it ----------------------------------------------------
// The container carries what the element owns; the field is not left behind as a leak.
// @kenbi
void fields_go_with_the_element(struct list *l) {
  /* @mem t::e { free: free, owner: e } */
  struct elem *e = (struct elem *)malloc(sizeof(*e));
  if (e == NULL) return;
  /* @mem t::nm { free: free, owner: name } */
  e->name = (char *)malloc(8);
  (void)AppendToList(l, e);
}

// --- 6. handing away a pointer this function does not own is default-red -----------------------
// The caller may free it too, so the transfer is unverifiable until the intake is declared.
// @kenbi
void hands_away_a_borrowed_parameter(struct list *l, struct elem *e) {
  (void)AppendToList(l, e);   //EXPECT UNCONTRACTED_MOVE
}

// --- 7. …and with the intake declared, it is the discharge ------------------------------------
// @kenbi
// @frees(e)
void passes_ownership_on(struct list *l, struct elem *e) {
  (void)AppendToList(l, e);
}

// --- 8. handing away something only borrowed is a bug ------------------------------------------
// @kenbi
// @borrows(e)
void hands_away_a_borrow(struct list *l, struct elem *e) {
  (void)AppendToList(l, e);   //EXPECT BORROW_MOVED
}

// --- 9. releasing first, then handing it over --------------------------------------------------
// @kenbi
void freed_then_handed_over(struct list *l) {
  /* @mem t::e { free: free, owner: e } */
  struct elem *e = (struct elem *)malloc(sizeof(*e));
  if (e == NULL) return;
  free(e);
  (void)AppendToList(l, e);   //EXPECT USE_AFTER_FREE
}
