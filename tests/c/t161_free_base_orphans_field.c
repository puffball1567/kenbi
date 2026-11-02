#include <stdlib.h>
// FIELD OWNERSHIP (#2b, struct-lifetime slice): freeing the container orphans an owned field.
// `free(b)` releases the struct — after it, `b->buf` is inaccessible, so a field that still owns
// a resource is leaked by the free (you freed the struct without releasing its member). kenbi
// reports it at the field allocation's line, and only when the field is *provably* orphaned:
// MUST-owned here, a tracked field origin, and no OTHER live key still reaches it (an out-of-
// struct alias defers the case). A parameter base is the caller's struct — its field is the
// caller's obligation (deferred), so this fires only for a function-owned container.
typedef struct { int *buf; } box_t;

// RED: the container is freed while its field still owns the buffer.
void free_orphans_field(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));   //EXPECT LEAK
  free(b);                            // orphans b->buf
}

// GREEN: the field is released before the container — the ordered teardown.
void free_field_then_base(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));
  free(b->buf);
  free(b);
}

// GREEN: an out-of-struct alias (`p`) can still free the buffer after `free(b)` — the free does
// not orphan it, so this aliased case is deferred, not accused.
void aliased_field_not_orphaned(int n) {
  /* @mem demo::box { free: free, owner: b } */
  box_t *b = malloc(sizeof(box_t));
  /* @mem demo::buf { free: free, owner: p } */
  int *p = malloc(n * sizeof(int));
  b->buf = p;
  free(b);
  free(p);
}

// GREEN: the base is a PARAMETER — the caller owns the struct, so the field's release is the
// caller's obligation (never freed here, so no orphaning free occurs).
void param_base_defers(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: buf } */
  b->buf = malloc(n * sizeof(int));
}
