#include <stdlib.h>
// FIELD OWNERSHIP (#2b increment): store-over-owned = LEAK. Overwriting a one-level field path
// (`b->buf`) that still OWNS a resource orphans that resource — the store drops the field's only
// handle to it. kenbi reports the leak at the orphaned allocation's line, but ONLY when the old
// origin is *provably* orphaned by the store: MUST-owned here, a tracked field origin, and no
// OTHER live key still reaches it. This fires for both an overwriting field-alloc (`b->buf = malloc`)
// and an overwriting field-store (`b->buf = p`). The aliased case stays deferred (no false leak).
typedef struct { int *buf; } box_t;
void use(int *q);

// RED: a fresh allocation overwrites a field that still owns the previous one.
void overwrite_alloc(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  b->buf = malloc(n * sizeof(int));   //EXPECT LEAK
  /* @mem demo::buf { free: free, owner: p } */
  b->buf = malloc(n * sizeof(int));   // orphans the first buffer
}

// RED: storing another owned pointer overwrites a field that still owns a direct allocation.
void overwrite_store(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  b->buf = malloc(n * sizeof(int));   //EXPECT LEAK
  /* @mem demo::buf { free: free, owner: q } */
  int *q = malloc(n * sizeof(int));
  b->buf = q;                          // orphans the first buffer
}

// GREEN: the previous buffer is released before the field is overwritten — no leak.
void free_then_overwrite(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  b->buf = malloc(n * sizeof(int));
  free(b->buf);
  /* @mem demo::buf { free: free, owner: p } */
  b->buf = malloc(n * sizeof(int));
  free(b->buf);
}

// GREEN: the old field value still has a LIVE local alias (`p`) that can free it — the overwrite
// does not orphan it, so this aliased case is deferred, not accused here.
void aliased_overwrite(box_t *b, int n) {
  /* @mem demo::buf { free: free, owner: p } */
  int *p = malloc(n * sizeof(int));
  b->buf = p;
  /* @mem demo::buf { free: free, owner: q } */
  int *q = malloc(n * sizeof(int));
  b->buf = q;
  free(p);
  free(q);
}
