#include <stdlib.h>
typedef struct arena arena_t;
// @arena pool { create: arena_create, alloc: arena_alloc, free: arena_destroy }
arena_t *arena_create(void);
void *arena_alloc(arena_t *a, int n);
void arena_destroy(arena_t *a);
typedef struct { int v; } node_t;
// @arena_alloc(a)
node_t *make(arena_t *a);
void use(node_t *n);
void f(void) {
  arena_t *R = arena_create();
  node_t *p = make(R);
  use(p);                        // used while the region is alive -> clean
  arena_destroy(R);
}
