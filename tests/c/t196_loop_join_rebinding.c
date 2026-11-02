#include <stdlib.h>
// BINDINGS AT A LOOP EXIT. A while / for loop may run zero times: the exit is reached with the
// ENTRY bindings as well as the body's. `free(data); while (c) { data = malloc; } use(data)`
// used the body's fresh binding only, so the 0-trip path — `data` still the freed one — was
// forgotten. The loop exit reconciles the entry bindings like an if-join.

// @borrows(s)
void use(char *s);

// freed before the loop, rebound inside it: after the loop it may still be the freed one
static void uaf_zero_trip(int c) {
  /* @mem t::a { free: free, owner: data } */
  char *data = malloc(8);
  free(data);
  while (c) {
    /* @mem t::b { free: free, owner: data } */
    data = malloc(8);
    c = 0;
  }
  use(data);    //EXPECT USE_AFTER_FREE
  free(data);   //EXPECT DOUBLE_FREE
}

// the body only uses; freed once after -> clean
static void loop_use_ok(int c) {
  /* @mem t::c { free: free, owner: data } */
  char *data = malloc(8);
  while (c) {
    use(data);
    c--;
  }
  free(data);
}
