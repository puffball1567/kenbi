#include <stdlib.h>
// A CONSTANT SWITCH selects one group (the Juliet 15 shape): `switch (6)` runs `case 6:` only,
// `switch (8)` with no `case 8:` runs `default:` only. Lowering every case as a possible
// branch would analyse paths the program cannot take — `case 7:` (no free) next to
// `default: free(data)` looked like a leak. Folded like `if (1)`; only when the selected group
// ends in a break / return (no fall-through), so nothing reachable is dropped.

// @borrows(s)
void use(char *s);

// case 6 allocates, default of the second switch frees -> clean
static void const_switch_ok(void) {
  char *data = NULL;
  switch (6) {
  case 6:
    /* @mem t::a { free: free, owner: data } */
    data = malloc(8);
    break;
  default:
    use("x");
    break;
  }
  switch (8) {
  case 7:
    use("y");
    break;
  default:
    free(data);
    break;
  }
}

// the selected group of the second switch does NOT free -> leak
static void const_switch_leak(void) {
  char *data = NULL;
  switch (6) {
  case 6:
    /* @mem t::b { free: free, owner: data } */
    data = malloc(8);   //EXPECT LEAK
    break;
  default:
    use("x");
    break;
  }
  switch (7) {
  case 7:
    use("y");
    break;
  default:
    free(data);
    break;
  }
}

// a non-constant switch still joins every case: the no-free case is a possible leak
static void var_switch_maybe_leak(int c) {
  char *data = NULL;
  /* @mem t::c { free: free, owner: data } */
  data = malloc(8);   //EXPECT LEAK
  switch (c) {
  case 7:
    use("y");
    break;
  default:
    free(data);
    break;
  }
}

// the selected case frees twice across the two constant switches
static void const_switch_double_free(void) {
  char *data = NULL;
  /* @mem t::d { free: free, owner: data } */
  data = malloc(8);
  switch (1) {
  case 1:
    free(data);
    break;
  default:
    break;
  }
  switch (2) {
  case 2:
    free(data);   //EXPECT DOUBLE_FREE
    break;
  default:
    break;
  }
}
