#include <stdlib.h>
// A pointer allocated on one iteration is consumed on the next back edge.
// @allocator t::heap { alloc: malloc, free: free }
int again(void);
// @borrows(p)
void use(const char *p);

// @kenbi
void release_previous(void) {
  char *p = malloc(8);
  while (again()) {
    free(p);
    p = malloc(8);
  }
  free(p);
}

// @kenbi
void continue_previous(void) {
  char *p = malloc(8);
  while (again()) {
    free(p);
    p = malloc(8);
    continue;
  }
  free(p);
}

// @kenbi
void break_keeps_obligation(void) {
  char *p = NULL;
  while (again()) {
    p = malloc(8); //EXPECT LEAK
    break;
  }
}

// @kenbi
void carried_use_after_release(void) {
  char *p = malloc(8);
  free(p);
  while (again()) {
    use(p); //EXPECT USE_AFTER_FREE
    p = malloc(8);
    free(p);
  }
}
