#include <stdlib.h>
typedef struct arena arena_t;
typedef struct { int x; } item_t;
// @arena pool { create: arena_create, alloc: arena_alloc, free: arena_destroy }
arena_t *arena_create(void);
void *arena_alloc(arena_t *a, int n);
void arena_destroy(arena_t *a);
// @moves(item)
void sink(item_t *item);
// @kenbi
void f(void) {
  arena_t *R = arena_create();
  item_t *p = arena_alloc(R, sizeof(item_t));
  sink(p);            // arena still alive: individually transferring region memory is illegal   //EXPECT BORROW_MOVED
  arena_destroy(R);
}
