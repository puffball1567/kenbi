#include <stdlib.h>
// BINDINGS ARE PER CASE. A switch's cases each start from the bindings at the switch entry
// and the join reconciles them (like an if-join): a case that allocates and frees next to a
// case that only allocates leaves a may-freed `data` after the switch.

// @borrows(s)
void use(char *s);

// case 1 frees, case 2 does not: a use after the switch may be a use after free
static void uaf_across_switch(int c) {
  char *data = NULL;
  switch (c) {
  case 1:
    /* @mem t::a { free: free, owner: data } */
    data = malloc(8);
    free(data);
    break;
  default:
    /* @mem t::b { free: free, owner: data } */
    data = malloc(8);
    break;
  }
  use(data);    //EXPECT USE_AFTER_FREE
  free(data);   //EXPECT DOUBLE_FREE
}

// every case allocates, none frees before the join, one free after -> clean
static void switch_both_ok(int c) {
  char *data = NULL;
  switch (c) {
  case 1:
    /* @mem t::c { free: free, owner: data } */
    data = malloc(8);
    break;
  default:
    /* @mem t::d { free: free, owner: data } */
    data = malloc(16);
    break;
  }
  use(data);
  free(data);
}

// no default: the no-match path keeps the entry binding (NULL) — the allocating case leaks
static void switch_no_default_leak(int c) {
  char *data = NULL;
  switch (c) {
  case 1:
    /* @mem t::e { free: free, owner: data } */
    data = malloc(8);   //EXPECT LEAK
    break;
  }
  use(data);
}
