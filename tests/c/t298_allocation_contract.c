/* Independently authored inputs: storage returned by an allocating API contract, its size and
   declared alignment, release, reuse of an allocation site, and borrows of allocated buffers. */
typedef unsigned long size_t;
void *get(size_t n);
void *get_array(size_t count, size_t size);
void put(void *p);
void free(void *p);
int runtime_size(void);
void start(int *t, const void *b);
void finish(int *t);

/* ---- size, alignment, and release ------------------------------------------------------------ */

int within(void) { char *p = get(16); if (!p) return 0; p[15] = 1; int v = p[0]; put(p); return v; }
int past_end(void) { char *p = get(16); if (!p) return 0; p[16] = 1; put(p); return 0; }  /* PROTOCOL_EXPECT SOURCE_ACCESS_RANGE */
int array_within(void) { int *p = get_array(4, sizeof(int)); if (!p) return 0; p[3] = 1; put(p); return 0; }
int array_past_end(void) { int *p = get_array(4, sizeof(int)); if (!p) return 0; p[4] = 1; put(p); return 0; }  /* PROTOCOL_EXPECT SOURCE_ACCESS_RANGE */
int size_unknown(void) { int n = runtime_size(); char *p = get(n); if (!p) return 0; p[0] = 1; put(p); return 0; }  /* PROTOCOL_EXPECT UNKNOWN_SOURCE_ACCESS_RANGE */
int aligned_word(void) { long long *p = get(16); if (!p) return 0; p[1] = 1; put(p); return 0; }
int cast_to_bytes(void) { unsigned char *p = (unsigned char *)get(8); if (!p) return 0; p[7] = 1; put(p); return 0; }
int null_unchecked(void) { char *p = get(16); p[0] = 1; put(p); return 0; }  /* PROTOCOL_EXPECT NULL_POINTER_ACCESS */
int use_after_put(void) { char *p = get(16); if (!p) return 0; put(p); return p[0]; }  /* PROTOCOL_EXPECT EXPIRED_BORROW_ORIGIN */
int double_put(void) { char *p = get(16); if (!p) return 0; put(p); put(p); return 0; }  /* PROTOCOL_EXPECT EXPIRED_BORROW_ORIGIN */
int alias_after_put(void) { char *p = get(16); if (!p) return 0; char *q = p + 4; put(p); return q[0]; }  /* PROTOCOL_EXPECT EXPIRED_BORROW_ORIGIN */
int two_objects(void) {
  char *p = get(8); if (!p) return 0;
  char *q = get(8); if (!q) { put(p); return 0; }
  put(p); q[7] = 1; put(q); return 0;
}

/* ---- what may be released, and by whom -------------------------------------------------------- */

static void release_it(char *p) { free(p); }  /* PROTOCOL_EXPECT RELEASE_NOT_ALLOCATED */  //EXPECT UNCONTRACTED_RELEASE
int free_automatic(void) { char b[8]; release_it(b); return 0; }
int free_automatic_alias(void) { char b[8]; char *p = b + 0; free(p); return 0; }  /* PROTOCOL_EXPECT RELEASE_NOT_ALLOCATED */  //EXPECT UNCONTRACTED_RELEASE
int wrong_releaser(void) { char *p = get(8); if (!p) return 0; free(p); return 0; }  /* PROTOCOL_EXPECT RELEASE_ALLOCATOR_MISMATCH */  //EXPECT UNCONTRACTED_RELEASE
int put_interior(void) { char *p = get(8); if (!p) return 0; put(p + 1); return 0; }  /* PROTOCOL_EXPECT RELEASE_NOT_ALLOCATION_START */
int put_after_walk(void) { char *p = get(8); if (!p) return 0; char *q = p + 2; q = q - 2; put(q); return 0; }
int free_null_constant(void) { free(0); return 0; }
int free_null_variable(void) { char *p = 0; free(p); return 0; }  //EXPECT UNCONTRACTED_RELEASE
int put_unknown_size(void) { int n = runtime_size(); char *p = get(n); if (!p) return 0; put(p); return 0; }

/* ---- the null check written with a NULL macro -------------------------------------------------- */

#define NULL ((void *)0)
int null_macro(void) { char *p = get(16); if (p == NULL) return 0; p[0] = 1; put(p); return 0; }
int null_macro_left(void) { char *p = get(16); if (NULL != p) { p[0] = 1; put(p); } return 0; }
int null_macro_wrong_branch(void) { char *p = get(16); if (p != NULL) return 0; p[0] = 1; return 0; }  /* PROTOCOL_EXPECT NULL_POINTER_ACCESS */
#define IS_NULL(x) ((x) == NULL)
int comparison_macro(void) { char *p = get(16); if (IS_NULL(p)) return 0; p[0] = 1; put(p); return 0; }

/* ---- an allocation site reached again ---------------------------------------------------------- */

int loop_put_each(int n) {
  for (int i = 0; i < n; i++) { char *p = get(8); if (!p) return 0; p[0] = 1; put(p); }
  return 0;
}
int loop_stale_pointer(int n) {
  char *old = 0;
  for (int i = 0; i < n; i++) {
    char *p = get(8); if (!p) return 0;
    if (old) old[0] = 1;                                  /* PROTOCOL_EXPECT EXPIRED_BORROW_ORIGIN */
    old = p; put(p);
  }
  return 0;
}
int loop_keeps_previous(int n) {
  char *old = 0;
  for (int i = 0; i < n; i++) {
    char *p = get(8); if (!p) break;
    if (old) { old[7] = 1; put(old); }                    /* the previous object is still live */
    old = p;
  }
  if (old) put(old);
  return 0;
}
static char *make(void) { return get(8); }
int helper_twice(void) {
  char *a = make(); if (!a) return 0;
  put(a);
  char *b = make(); if (!b) return 0;
  b[0] = 1; put(b);
  return a[0];                                             /* PROTOCOL_EXPECT EXPIRED_BORROW_ORIGIN */
}
int helper_twice_good(void) {
  char *a = make(); if (!a) return 0;
  char *b = make(); if (!b) { put(a); return 0; }
  a[0] = 1; b[0] = 1; put(a); put(b);
  return 0;
}

/* ---- borrows of allocated buffers -------------------------------------------------------------- */

int borrow_then_put(void) {
  int t; char *p = get(16); if (!p) return 0;
  start(&t, p); finish(&t); put(p); return 0;
}
int put_while_borrowed(void) {
  int t; char *p = get(16); if (!p) return 0;
  start(&t, p); put(p); finish(&t); return 0;             /* PROTOCOL_EXPECT BORROW_ACCESS_CONFLICT */
}
int borrow_too_small(void) {
  int t; char *p = get(8); if (!p) return 0;
  start(&t, p); finish(&t); put(p); return 0;             /* PROTOCOL_EXPECT BORROW_CAPACITY_REQUIREMENT */
}
