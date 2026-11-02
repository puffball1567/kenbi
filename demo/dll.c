#include <stdlib.h>

/* A doubly-linked list with back-references (next AND prev). In safe Rust this
   needs `unsafe` raw pointers (or Rc<RefCell<..>>/Weak, runtime-checked): the
   borrow checker cannot express the shared, cyclic ownership of prev/next.
   Under kenbi's @arena discipline it is verified memory-safe with no @unsafe:
   every node lives in the arena, cross-pointers share the arena's lifetime, no
   node is freed individually, and nothing is used after the region is destroyed. */

typedef struct node {
  int val;
  struct node *next;
  struct node *prev;
} node_t;

typedef struct arena arena_t;
// @arena pool { create: arena_create, alloc: arena_alloc, free: arena_destroy }
arena_t *arena_create(void);
void *arena_alloc(arena_t *a, int n);
void arena_destroy(arena_t *a);
void use_val(int v);

void run(int n) {
  arena_t *R = arena_create();
  node_t *head = arena_alloc(R, sizeof(node_t));
  head->val = 0;
  head->next = NULL;
  head->prev = NULL;
  node_t *cur = head;
  for (int i = 1; i < n; i++) {
    node_t *m = arena_alloc(R, sizeof(node_t));
    m->val = i;
    m->prev = cur;            // back-reference — the part that needs unsafe in Rust
    m->next = NULL;
    cur->next = m;            // forward-reference
    cur = m;
  }
  for (node_t *p = head; p; p = p->next) use_val(p->val);   // forward traverse
  for (node_t *p = cur;  p; p = p->prev) use_val(p->val);   // backward traverse (via prev)
  arena_destroy(R);           // free the whole region once
}
