#include <stdlib.h>

/* The other C list: nodes on the heap, chained through a field, released one at a time.
   It is not an arena (see demo/dll.c) — each node IS freed individually — and it is where
   a per-allocation-site resource model shows through: every node comes from the same
   `malloc`, so without a declaration kenbi sees one object where the program has a chain,
   and every walk along the chain reads as a use after free.

   Two declarations make it checkable, and kenbi verifies both rather than trusting them:
   `link:` says the resource is a NODE of a collection chained through `next`, and
   `@drains(head)` says the last loop releases every element of it. */

typedef struct Node {
  struct Node *next;
  int v;
} Node;

// @borrows(n)
void use(Node *n);

void run(int k)
{
  Node *head = NULL, *cur, *nxt;

  /* @mem demo::node { free: free, owner: cur, link: next } */
  for (int i = 0; i < k; i++) {
    cur = (Node *) malloc(sizeof(*cur));
    cur->next = head;                 /* link the new node in front */
    head = cur;
  }

  for (cur = head; cur != NULL; cur = cur->next)   /* walk: each step is another element */
    use(cur);

  /* @drains(head) */
  for (cur = head; cur != NULL; cur = nxt) {
    nxt = cur->next;                  /* save the link BEFORE releasing this element */
    free(cur);
  }
}

/* What is still checked, all of it statically and on every path:
     - drop the `@drains` and the collection is a LEAK;
     - write `for (cur = head; cur; cur = cur->next) free(cur);` and reading the link out of
       the element just released is a USE_AFTER_FREE;
     - release a cursor twice before it advances and that is a DOUBLE_FREE;
     - touch head or any cursor after the drain and that is a USE_AFTER_FREE;
     - declare `@drains` on a loop that releases nothing and that is CONTRACT_NOT_HONORED.
   See tests/c/t207_intrusive_list.c for each of those as an executable assertion. */
