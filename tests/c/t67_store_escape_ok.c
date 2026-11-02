#include <stdlib.h>
// FIELD OWNERSHIP (#2 increment). Storing an owned pointer into a one-level field path
// (`b->buf = p`) transfers ownership to the FIELD: kenbi tracks a double-free / use-after-free
// THROUGH the field (exactly like a direct `b->buf = malloc`), instead of dropping tracking with
// an ESCAPE_UNCHECKED advisory. The field is excluded from the leak scan — the base struct may
// escape carrying the obligation (full field LIFETIME / leak modelling is the deferred #2 work).
typedef struct { int *buf; } box_t;
void use(int *q);

// GREEN: store into the field and nothing else — no false leak, and (now) no advisory: the field
// owns the buffer and its release is the base struct's obligation.
void store_ok(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  int *p = malloc(n * sizeof(int));
  b->buf = p;
}

// RED: the buffer is released twice through the field.
void double_free_field(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  int *p = malloc(n * sizeof(int));
  b->buf = p;
  free(b->buf);
  free(b->buf);          //EXPECT DOUBLE_FREE
}

// RED: the field is used after the buffer it owns is freed.
void uaf_field(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  int *p = malloc(n * sizeof(int));
  b->buf = p;
  free(b->buf);
  use(b->buf);           //EXPECT USE_AFTER_FREE
}
