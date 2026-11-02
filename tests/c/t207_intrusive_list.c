#include <stdlib.h>
// AN INTRUSIVE LINKED LIST, DECLARED. Every node comes from one allocation site, so kenbi sees
// one resource where the program has a chain of objects: a release in a walk read as a release
// of "the" resource, the next step as a use after free, and a list nothing drains looked no
// different from a list fully released. `link: <field>` says the resource is a NODE of a
// collection chained through that field, and `@drains(head)` says a loop releases every element
// of the collection rooted there. Neither is trusted: the drain is verified against the loop,
// the collection is discharged only by it, and after it every cursor dangles.

typedef struct Node { struct Node *next; int v; } Node;
typedef struct Other { struct Other *next; char *buf; } Other;

// @borrows(n)
void use(Node *n);

// build, walk, release: clean
static void build_walk_release(int k) {
  Node *head = NULL, *cur, *nxt;
  /* @mem t::n { free: free, owner: cur, link: next } */
  for (int i = 0; i < k; i++) {
    cur = (Node *) malloc(sizeof(*cur));
    cur->next = head;
    head = cur;
  }
  for (cur = head; cur != NULL; cur = cur->next)
    use(cur);
  /* @drains(head) */
  for (cur = head; cur != NULL; cur = nxt) {
    nxt = cur->next;
    free(cur);
  }
}

// nothing drains it: the collection is abandoned
static void never_drained(int k) {
  Node *head = NULL, *cur;
  /* @mem t::a { free: free, owner: cur, link: next } */
  for (int i = 0; i < k; i++) {
    cur = (Node *) malloc(sizeof(*cur));   //EXPECT LEAK
    cur->next = head;
    head = cur;
  }
  for (cur = head; cur != NULL; cur = cur->next)
    use(cur);
}

// the classic: release the element, then read the link out of it
static void walk_out_of_freed(int k) {
  Node *head = NULL, *cur;
  /* @mem t::b { free: free, owner: cur, link: next } */
  for (int i = 0; i < k; i++) {
    cur = (Node *) malloc(sizeof(*cur));
    cur->next = head;
    head = cur;
  }
  /* @drains(head) */
  for (cur = head; cur != NULL; cur = cur->next)   //EXPECT USE_AFTER_FREE
    free(cur);
}

// every cursor dangles once the collection is drained
static void use_after_drain(int k) {
  Node *head = NULL, *cur, *nxt;
  /* @mem t::c { free: free, owner: cur, link: next } */
  for (int i = 0; i < k; i++) {
    cur = (Node *) malloc(sizeof(*cur));
    cur->next = head;
    head = cur;
  }
  /* @drains(head) */
  for (cur = head; cur != NULL; cur = nxt) {
    nxt = cur->next;
    free(cur);
  }
  use(head);   //EXPECT USE_AFTER_FREE
}

// the declaration is checked against the loop: this one releases nothing
static void lying_drain(int k) {
  Node *head = NULL, *cur, *nxt;
  /* @mem t::d { free: free, owner: cur, link: next } */
  for (int i = 0; i < k; i++) {
    cur = (Node *) malloc(sizeof(*cur));   //EXPECT LEAK
    cur->next = head;
    head = cur;
  }
  /* @drains(head) */
  for (cur = head; cur != NULL; cur = nxt) {   //EXPECT CONTRACT_NOT_HONORED
    nxt = cur->next;
    use(cur);
  }
}

// the same element released twice, before the cursor moves on
static void element_twice(int k) {
  Node *head = NULL, *cur, *nxt;
  /* @mem t::e { free: free, owner: cur, link: next } */
  for (int i = 0; i < k; i++) {
    cur = (Node *) malloc(sizeof(*cur));
    cur->next = head;
    head = cur;
  }
  /* @drains(head) */
  for (cur = head; cur != NULL; cur = nxt) {
    nxt = cur->next;
    free(cur);
    free(cur);   //EXPECT DOUBLE_FREE
  }
}

// declaring a link on one resource does not make every `next` field a collection: an
// unrelated struct's link is still a pointer kenbi cannot place
static void unrelated_next(Other *o) {
  Other *q = o->next;
  free(q);   //EXPECT UNCONTRACTED_RELEASE
}
