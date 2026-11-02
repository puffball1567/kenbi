#include <stdlib.h>
// FIELD OWNERSHIP (#2b, struct-lifetime slice): a field left owned when its LOCAL container goes
// out of scope leaks. Field origins are not leak-scanned as ordinary locals (the container may
// carry the obligation away); this catches the case where it demonstrably does not — a function-
// local heap container that is itself still owned (leaking) at the exit, so the field it still
// owns leaks too. It stays sound by DEFERRING every case where the obligation could have left:
//  - a parameter base (the caller owns the struct — its field is the caller's obligation);
//  - the container escaped (returned / stored out / moved to a sink) — it carried the field;
//  - the field value itself escaped (`return b->buf` / `p = b->buf` / a `@moves`/`@frees` sink).
typedef struct { int *buf; } box_t;

// RED x2: a local heap container and its field are both abandoned at scope exit.
void leak_both(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));   //EXPECT LEAK
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));   //EXPECT LEAK
}

// GREEN: correct teardown — field released, then container.
void teardown_ok(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));
  free(b->buf);
  free(b);
}

// GREEN for the field: `return b->buf` transfers the field value out. The container is still a
// leak (it is never freed), but the field it once held is not.
int *return_field(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));   //EXPECT LEAK
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));
  return b->buf;                      // field escapes -> not a field leak
}

// GREEN: the container escapes (returned), carrying the field's obligation with it.
box_t *return_container(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));
  return b;
}

// GREEN: an out-of-struct alias (`r`) carries the buffer past the container's free.
int *alias_out(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));
  int *r = b->buf;
  free(b);
  return r;
}

// GREEN: a PARAMETER container is the caller's struct — its field is the caller's obligation.
void param_container(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));
}
