#include <stdlib.h>
// BINDINGS ARE PER PATH. `if (c) { data = malloc; free(data); } else { data = malloc; }` binds
// `data` to two different origins; after the join a use may hit the freed one (the Juliet 12
// shape: two allocations, one freed, under a runtime condition). The join keeps one binding
// and gives its origin the other path's states too — a use is a may-UAF, a free a may-double
// free — instead of forgetting the freed origin (a use after the join passed as GREEN).

// @borrows(s)
void use(char *s);

// freed on the then path only: the later use may be a use after free, the later free a
// second free
static void uaf_across_join(int c) {
  char *data = NULL;
  if (c) {
    /* @mem t::a { free: free, owner: data } */
    data = malloc(8);
    free(data);
  } else {
    /* @mem t::b { free: free, owner: data } */
    data = malloc(8);
  }
  use(data);    //EXPECT USE_AFTER_FREE
  free(data);   //EXPECT DOUBLE_FREE
}

// the else path does not rebind: the then path's binding survives the join
static void then_only_binding(int c) {
  char *data = NULL;
  if (c) {
    /* @mem t::c { free: free, owner: data } */
    data = malloc(8);   //EXPECT LEAK
  } else {
    use("x");
  }
  use(data);
}

// both paths allocate and neither frees before the join, one free after -> clean
static void both_paths_ok(int c) {
  char *data = NULL;
  if (c) {
    /* @mem t::d { free: free, owner: data } */
    data = malloc(8);
  } else {
    /* @mem t::e { free: free, owner: data } */
    data = malloc(16);
  }
  use(data);
  free(data);
}
