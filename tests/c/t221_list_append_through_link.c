#include <stdlib.h>
// GROWING AN INTRUSIVE COLLECTION. `@list <Type> { link: <field> }` declares that objects of a
// record type are nodes of a chain, and the chain's origin stands for the WHOLE collection —
// discharged by a declared `@drains` loop, never inferred. But a C list grows by assigning
// through the link field:
//
//     cur->next = Acquire(...);   cur = cur->next;
//
// and that assignment read as "a field the local `cur` owns", so every list-building loop
// leaked once per node ON TOP of the collection's own obligation. An assignment to the DECLARED
// LINK FIELD is the next element of the collection the base is already in, not a new one.
// MagickCore's cluster and interval-tree builders are written exactly this way.

// @allocator t::fam { alloc: acq, free_returns_null: rel }
void *acq(unsigned long n, unsigned long s);
void *rel(void *p);

// @list Node { link: next }
typedef struct node_t { struct node_t *next; char *payload; } Node;

// GREEN: built by appending through the link, drained by a declared loop.
// @kenbi
void build_and_drain(int n) {
  Node *head = (Node *) 0, *cur = (Node *) 0, *nx;
  int i;
  for (i = 0; i < n; i++) {
    if (head != (Node *) 0) {
      cur->next = (Node *) acq(1, sizeof(*cur->next));
      cur = cur->next;   //EXPECT UNKNOWN_VAR
    } else {
      cur = (Node *) acq(1, sizeof(*cur));
      head = cur;
    }
  }
  /* @drains(head) */
  for (cur = head; cur != (Node *) 0; cur = nx) {   //EXPECT UNKNOWN_VAR
    nx = cur->next;   //EXPECT UNKNOWN_VAR
    cur = (Node *) rel(cur);
  }
}

// RED: the collection is built and never drained. One finding for the COLLECTION — not one per
// appended node, which is the whole point: the origin stands for the chain.
// @kenbi
void build_and_abandon(int n) {
  Node *head = (Node *) 0, *cur = (Node *) 0;
  int i;
  for (i = 0; i < n; i++) {
    if (head != (Node *) 0) {
      cur->next = (Node *) acq(1, sizeof(*cur->next));
      cur = cur->next;   //EXPECT UNKNOWN_VAR
    } else {
      cur = (Node *) acq(1, sizeof(*cur));   //EXPECT LEAK
      head = cur;
    }
  }
}

// RED: a NON-link field of the same record is an ordinary owned field and still leaks. The
// exemption is for the declared link only.
// @kenbi
void payload_leaks(void) {
  Node *own = (Node *) acq(1, sizeof(*own));   //EXPECT LEAK
  own->payload = (char *) acq(8, 1);   //EXPECT LEAK
}
