#include <stdlib.h>
// FIELD OWNERSHIP (#2b, struct-lifetime slice): a STACK-VALUE local container that owns a field.
// The struct dies at scope exit, so a field it still owns leaks. kenbi does NOT silently assume
// the container carried the obligation away (default-red / declare-don't-infer): only a self-
// evident whole-struct `return b` transfers it; every OTHER unrecognised container escape stays
// RED — its still-owned field leaks, and the user declares the transfer (or marks it @unsafe).
typedef struct { int *buf; } box_t;
void save(box_t *p);

// RED: the stack struct dies with the field still owned.
void leak_stack(int n) {
  box_t b;
  /* @mem demo::buf { free: free, owner: buf } */
  b.buf = malloc(n * sizeof(int));   //EXPECT LEAK
}

// GREEN: the field is released before the struct dies.
void free_stack(int n) {
  box_t b;
  /* @mem demo::buf { free: free, owner: buf } */
  b.buf = malloc(n * sizeof(int));
  free(b.buf);
}

// GREEN: `return b` transfers the whole struct — a self-evident hand-off of its fields.
box_t return_struct(int n) {
  box_t b;
  /* @mem demo::buf { free: free, owner: buf } */
  b.buf = malloc(n * sizeof(int));
  return b;
}

// GREEN: `return b.buf` transfers the field value.
int *return_field(int n) {
  box_t b;
  /* @mem demo::buf { free: free, owner: buf } */
  b.buf = malloc(n * sizeof(int));
  return b.buf;
}

// RED (default-red): `&b` goes to an uncontracted callee — kenbi cannot verify it takes the
// field's ownership, so it does not assume so. The field leaks; declare the transfer / @unsafe.
void addr_escape(int n) {
  box_t b;
  /* @mem demo::buf { free: free, owner: buf } */
  b.buf = malloc(n * sizeof(int));   //EXPECT LEAK
  save(&b);
}

// GREEN: the user vouches for the container escape by marking the allocation @unsafe.
void addr_escape_vouched(int n) {
  box_t b;
  /* @mem demo::buf { free: free, owner: buf } */
  b.buf = malloc(n * sizeof(int));  // @unsafe
  save(&b);
}
