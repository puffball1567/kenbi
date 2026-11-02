#include <stdlib.h>
// A PROJECT'S OWN ALLOCATOR FAMILY, DECLARED ONCE. Nearly every C project wraps malloc
// (`AcquireMagickMemory` / `xmalloc` / `mem_alloc` …); until those wrappers are declared kenbi
// has no vocabulary for them and says nothing about that memory at all. `@allocator` names the
// family once — in the header everyone includes — instead of a `@mem` at every call site:
// every result is then a tracked owned resource, an unreleased one is a definite LEAK, and
// releasing it with anything but the declared function is WRONG_DEALLOCATOR.

// @allocator proj::mem { alloc: mem_alloc mem_alloc_n, realloc: mem_resize, free: mem_free }
void *mem_alloc(int n);
void *mem_alloc_n(int count, int size);
void *mem_resize(void *p, int n);
void mem_free(void *p);

// @borrows(s)
void use(char *s);

// never released
static void leaks(void) {
  char *p = mem_alloc(8);   //EXPECT LEAK
  use(p);
}

// released with the declared function -> clean
static void ok(void) {
  char *p = mem_alloc_n(4, 8);
  use(p);
  mem_free(p);
}

// released twice
static void twice(void) {
  char *p = mem_alloc(8);
  mem_free(p);
  mem_free(p);   //EXPECT DOUBLE_FREE
}

// used after release
static void uaf(void) {
  char *p = mem_alloc(8);
  mem_free(p);
  use(p);   //EXPECT USE_AFTER_FREE
}

// released with the WRONG function: the family declares mem_free
static void wrong_deallocator(void) {
  char *p = mem_alloc(8);
  free(p);   //EXPECT WRONG_DEALLOCATOR
}

// the declared realloc continues the obligation rather than starting a new one — and, like the
// built-in realloc, its result is unreconciled until it is null-checked: releasing `q` here would
// be a no-op on OOM and leave the block `p` still holds unfreed.
static void resized_then_freed(void) {
  char *p = mem_alloc(8);   //EXPECT LEAK
  char *q = mem_resize(p, 16);
  mem_free(q);   //EXPECT REALLOC_UNVERIFIED
}
