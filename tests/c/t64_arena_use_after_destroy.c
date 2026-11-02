#include <stdlib.h>
typedef struct arena arena_t;
// @arena pool { create: arena_create, alloc: arena_alloc, free: arena_destroy }
arena_t *arena_create(void);
void *arena_alloc(arena_t *a, int n);
void arena_destroy(arena_t *a);
void use(char *p);
void f(void) {
  arena_t *R = arena_create();
  char *p = arena_alloc(R, 16);
  arena_destroy(R);
  use(p);                 // arena destroyed -> p dangles into a freed region   //EXPECT BORROW_OUTLIVES_OWNER
}
