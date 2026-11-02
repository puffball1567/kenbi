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
  free(p);                // individual free of an arena object -> the arena owns it   //EXPECT BORROW_FREED
  arena_destroy(R);
}
