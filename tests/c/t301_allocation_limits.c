/* Independently authored inputs: live allocated storage against a profile's byte budget and an
   allocator's declared capacity of live objects. */
typedef unsigned long size_t;
void *get(size_t n);           /* general allocator */
void *slot(size_t n);          /* fixed pool: a declared number of live objects */
void put(void *p);
void unslot(void *p);
char *copy_text(const char *s);  /* allocates, size not declared */
int runtime_size(void);

int within_budget(void) {
  char *a = get(64); if (!a) return 0;
  char *b = get(64); if (!b) { put(a); return 0; }
  put(a); put(b); return 0;
}
int over_budget(void) {
  char *a = get(64); if (!a) return 0;
  char *b = get(65); if (!b) { put(a); return 0; }     /* LIMIT_EXPECT HEAP_BUDGET_EXCEEDED */
  put(a); put(b); return 0;
}
int released_in_between(void) {
  char *a = get(100); if (!a) return 0;
  put(a);
  char *b = get(100); if (!b) return 0;
  put(b); return 0;
}
int size_unknown(void) { int n = runtime_size(); char *a = get(n); if (!a) return 0; put(a); return 0; }  /* LIMIT_EXPECT UNKNOWN_HEAP_USAGE */
int unsized_allocation(void) { char s[2] = {0}; copy_text(s); return 0; }                      /* LIMIT_EXPECT UNKNOWN_HEAP_USAGE */
int loop_released(int n) {
  for (int i = 0; i < n; i++) { char *a = get(100); if (!a) return 0; put(a); }
  return 0;
}
int loop_leaks(int n) {
  for (int i = 0; i < n; i++) { char *a = get(8); if (!a) return 0; }   /* LIMIT_EXPECT UNKNOWN_HEAP_USAGE */
  return 0;
}
int leaked_still_counts(void) {
  char *a = get(100); if (!a) return 0;
  a = 0;                                                    /* the object is unreachable, not released */
  char *b = get(100); if (!b) return 0;                     /* LIMIT_EXPECT HEAP_BUDGET_EXCEEDED */
  put(b); return 0;
}

int pool_within(void) {
  char *a = slot(16); if (!a) return 0;
  char *b = slot(16); if (!b) { unslot(a); return 0; }
  unslot(a); unslot(b); return 0;
}
int pool_exhausted(void) {
  char *a = slot(16); if (!a) return 0;
  char *b = slot(16); if (!b) { unslot(a); return 0; }
  char *c = slot(16); if (!c) { unslot(a); unslot(b); return 0; }   /* LIMIT_EXPECT ALLOCATION_CAPACITY */
  unslot(a); unslot(b); unslot(c); return 0;
}
int pool_loop_leaks(int n) {
  for (int i = 0; i < n; i++) { char *a = slot(16); if (!a) return 0; }   /* LIMIT_EXPECT UNKNOWN_ALLOCATION_CAPACITY */
  return 0;
}
int pool_reused(void) {
  char *a = slot(16); if (!a) return 0;
  char *b = slot(16); if (!b) { unslot(a); return 0; }
  unslot(a);
  char *c = slot(16); if (!c) { unslot(b); return 0; }
  unslot(b); unslot(c); return 0;
}
