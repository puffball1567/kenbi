#include <stdlib.h>
// ONE PARAMETER, SEVERAL CONTRACTS — AND A NULL POINTER HAS NO FIELDS.
//
// A destructor for a linked structure declares three things about its one parameter: it frees
// the node, the string the node owns, and the sub-list it owns.
//
//     // @frees(n)  @frees(n.name)  @frees(n.next)
//     void destroy(struct node *n);
//
// Two defects met here, and each showed up as a finding on correct code:
//
//  1. The callsite applied exactly ONE contract per argument. `destroy(n)` released `n` and left
//     `n->name`'s obligation behind, so the very call that frees the field reported it as a leak
//     of that field.
//  2. Every such destructor opens with `if (n == NULL) return;`, and on that branch the null
//     guard discharged `n` but not the slots hanging off it — so a destructor that honestly
//     releases every field reported CONTRACT_NOT_HONORED for each of them.
//
// A null pointer has no fields either, and a parameter's several contracts all apply.

// @allocator t::heap { alloc: malloc, free: free }
struct node { struct node *next; char *name; };
// @borrows(p)
void use(const char *p);

// --- the destructor honours all three contracts ------------------------------------------------
// @kenbi
// @frees(n)
// @frees(n.next)
// @frees(n.name)
void destroy(struct node *n) {
  if (n == NULL) return;
  destroy(n->next);
  free(n->name);
  free(n);
}

// --- 1. the caller hands over the whole graph ---------------------------------------------------
// @kenbi
void hands_over_the_graph(void) {
  /* @mem t::n { free: free, owner: n } */
  struct node *n = (struct node *)malloc(sizeof(*n));
  if (n == NULL) return;
  n->next = NULL;
  /* @mem t::nm { free: free, owner: name } */
  n->name = (char *)malloc(8);
  destroy(n);
}

// --- 2. …and afterwards the node is gone, so touching it is a use after free ---------------------
// @kenbi
void uses_after_the_handover(void) {
  /* @mem t::n { free: free, owner: n } */
  struct node *n = (struct node *)malloc(sizeof(*n));
  if (n == NULL) return;
  n->next = NULL;
  /* @mem t::nm { free: free, owner: name } */
  n->name = (char *)malloc(8);
  destroy(n);
  use(n->name);   //EXPECT USE_AFTER_FREE USE_AFTER_FREE
}

// --- 3. releasing a field the destructor also releases is a double free ---------------------------
// @kenbi
void frees_the_field_too(void) {
  /* @mem t::n { free: free, owner: n } */
  struct node *n = (struct node *)malloc(sizeof(*n));
  if (n == NULL) return;
  n->next = NULL;
  /* @mem t::nm { free: free, owner: name } */
  n->name = (char *)malloc(8);
  destroy(n);
  free(n->name);   //EXPECT DOUBLE_FREE USE_AFTER_FREE
}

// --- 4. a destructor that does NOT release a field it declared is still caught ---------------------
// @kenbi
// @frees(m)
// @frees(m.name)
void forgets_the_field(struct node *m) {   //EXPECT CONTRACT_NOT_HONORED
  if (m == NULL) return;
  free(m);
}

// --- 5. a field the caller never gave away still leaks ---------------------------------------------
// `takes_node_only` declares only the node, so the caller keeps owing the field's release.
// @kenbi
// @frees(k)
void takes_node_only(struct node *k) {
  free(k);
}

// @kenbi
void keeps_owing_the_field(void) {
  /* @mem t::n { free: free, owner: n } */
  struct node *n = (struct node *)malloc(sizeof(*n));
  if (n == NULL) return;
  n->next = NULL;
  /* @mem t::nm { free: free, owner: name } */
  n->name = (char *)malloc(8);   //EXPECT LEAK
  takes_node_only(n);
}
