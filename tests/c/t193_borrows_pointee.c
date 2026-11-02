#include <stdlib.h>
// `@borrows(*p)`: the callee READS THROUGH the pointer it is handed (`char *d = *p; use(d)`), so
// `sink(&data)` is a use of `data` itself — after `free(data)` that is a use after free (the
// Juliet 63 / 64 shape: the sink reads the pointee of a `T **` after the source freed it).

// @borrows(*p)
void read_through(char **p);

// freed, then handed by address to a reader of the pointee
static void uaf_through_pointer(void) {
  /* @mem t::a { free: free, owner: data } */
  char *data = malloc(8);
  free(data);
  read_through(&data);   //EXPECT USE_AFTER_FREE
}

// read first, then freed -> clean
static void ok_through_pointer(void) {
  /* @mem t::b { free: free, owner: data } */
  char *data = malloc(8);
  read_through(&data);
  free(data);
}

// ... and through a pointer VARIABLE that holds the address (`void *` in between is common)
static void uaf_through_held_address(void) {
  /* @mem t::c { free: free, owner: data } */
  char *data = malloc(8);
  char **pp = &data;
  free(data);
  read_through(pp);   //EXPECT USE_AFTER_FREE
}
