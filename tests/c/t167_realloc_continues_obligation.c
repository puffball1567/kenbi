// @kenbi
#include <stdlib.h>
// `q = realloc(p, n)` CONTINUES the buffer's obligation — the old block at `p` is extended in place
// or freed-and-moved, so the result carries the SAME obligation, not a fresh one. kenbi cannot flatly
// verify the OOM failure path is reconciled (that needs the success / null-check correlation across a
// join), so a fresh-dest realloc is default-red (REALLOC_UNVERIFIED) unless the line carries a
// `@realloc` vouch. WITH the vouch kenbi trusts the reconciliation and still verifies the block is
// freed exactly once: the safe idiom frees once (GREEN), an unfreed result still leaks (RED).
struct box { char *data; };

// GREEN: the standard safe realloc idiom, vouched with @realloc (capture, null-check, free once).
void realloc_idiom_ok(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);
  if (!p) { return; }
  char *tmp = (char *)realloc(p, n);   // @realloc
  if (tmp) { p = tmp; }
  free(p);
}

// GREEN: self-realloc through a one-level struct field — vouched, the field keeps its obligation.
void realloc_field_ok(struct box *b, int n) {
  /* @mem g::buf { free: free, owner: data } */
  b->data = (char *)malloc(16);
  if (!b->data) { return; }
  char *t = (char *)realloc(b->data, n);   // @realloc
  if (t) { b->data = t; }
  free(b->data);
}

// RED: the reallocated buffer is never freed — the continued obligation still leaks (even vouched).
void realloc_result_leaks(int n) {
  /* @mem g::buf { free: free, owner: p } */
  char *p = (char *)malloc(16);   //EXPECT LEAK
  if (!p) { return; }
  char *tmp = (char *)realloc(p, n);   // @realloc
  if (tmp) { p = tmp; }
}
