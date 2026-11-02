// AN ALLOCATOR THE CODE IS GIVEN, not one it calls by name. zlib takes its allocator through
// the z_stream (`ZALLOC(strm,…)` expands to `(*((strm)->zalloc))(…)`), and sqlite, lua and most
// embedded APIs do the same. The declaration names the function-pointer FIELD, and both call
// spellings — `p->fn(...)` and the explicit `(*(p->fn))(...)` a macro expands to — resolve to
// it. Dereferencing a function pointer is a no-op in C, so the two are the same call.

typedef void *(*alloc_func)(void *opaque, unsigned items, unsigned size);
typedef void (*free_func)(void *opaque, void *address);
typedef struct { alloc_func zalloc; free_func zfree; void *opaque; } stream;

// @allocator z::mem { alloc: zalloc, free: zfree }
// @borrows(p)
void use(char *p);

// the macro form
static void macro_form_leaks(stream *strm) {
  char *p = (char *)(*((strm)->zalloc))((strm)->opaque, 1, 8);   //EXPECT LEAK
  use(p);
}

// the plain form, released -> clean
static void plain_form_ok(stream *strm) {
  char *p = (char *) strm->zalloc(strm->opaque, 1, 8);
  use(p);
  strm->zfree(strm->opaque, p);
}

// released twice through the injected deallocator
static void released_twice(stream *strm) {
  char *p = (char *) strm->zalloc(strm->opaque, 1, 8);
  (*((strm)->zfree))((strm)->opaque, p);
  strm->zfree(strm->opaque, p);   //EXPECT DOUBLE_FREE
}
