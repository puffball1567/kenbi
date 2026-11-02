#include <stdlib.h>
// A FAMILY HAS AS MANY RELEASE ENTRY POINTS AS IT DECLARES. Real projects allocate with one
// generic wrapper and release through typed destructors around it: ImageMagick builds a
// KernelInfo with `AcquireQuantumMemory` and releases it with `DestroyKernelInfo`, whose own
// body ends `kernel = RelinquishMagickMemory(kernel); return kernel;`. Three things were in the
// way of declaring that, and each one is a line of vocabulary or a fact kenbi was assuming.

typedef struct Map { char *name; int *levels; } Map;

// `free_returns_null:` may list several releases — all of them are accepted, where the check
// used to compare against the first name only and call every other one WRONG_DEALLOCATOR.
// `frees_fields:` says a typed destructor releases the object's owned FIELDS too, which is
// what it exists for; without it, freeing the container while a field still owns is a LEAK —
// the right default for a plain `free(s)`, wrong for a destructor.
// @allocator t::m { alloc: Acquire AcquireMap build, free_returns_null: Relinquish DestroyMap, frees_fields: DestroyMap }
// @allocator t::s { alloc: AcquireString, free_returns_null: DestroyString }
void *Acquire(int n);
Map *AcquireMap(void);
void *Relinquish(void *p);
Map *DestroyMap(Map *m);
char *AcquireString(const char *s);
char *DestroyString(char *s);
// @borrows(m)
void useMap(Map *m);

// the typed destructor is a declared release of the family: no WRONG_DEALLOCATOR
static void released_by_the_typed_destructor(void) {
  Map *m = AcquireMap();
  useMap(m);
  m = DestroyMap(m);
}

// ...and the generic one is still accepted for the same family
static void released_by_the_generic(void) {
  Map *m = (Map *) Acquire(sizeof(*m));
  useMap(m);
  m = (Map *) Relinquish(m);
}

// a release that is NOT on the family's list is still the wrong deallocator
static void released_by_a_stranger(void) {
  Map *m = AcquireMap();
  free(m);   //EXPECT WRONG_DEALLOCATOR
}

// the declared deep release discharges the object's owned fields
static void fields_released_with_the_object(void) {
  Map *m = AcquireMap();
  m->name = AcquireString("x");
  m = DestroyMap(m);
}

// ...while a release NOT declared deep still reports the abandoned field
static void fields_abandoned_by_a_shallow_release(void) {
  Map *m = (Map *) Acquire(sizeof(*m));
  m->name = AcquireString("x");   //EXPECT LEAK
  m = (Map *) Relinquish(m);
}

// A FACTORY THAT RETURNS ITS RELEASE'S RESULT RETURNS NULL, NOT A DANGLING POINTER. The error
// paths of a builder are written `return(DestroyMap(m));`, and the release is declared to hand
// back NULL — the same reasoning as the `m = DestroyMap(m); return m;` assign-back idiom, one
// shape over, and licensed by the same declaration. Read as a dangling result instead, every
// caller's use of the result became a use-after-free risk: 62 findings in one ImageMagick file.
// (`build` is listed in the family's `alloc:` above — the route that names the resource, so the
// result is leak-checked too, rather than `@owns` which leaves it unnamed.)
static Map *build(int bad) {
  Map *m = AcquireMap();
  if (bad)
    return DestroyMap(m);
  return m;
}

static void uses_the_result(int bad) {
  Map *m = build(bad);
  useMap(m);
  m = DestroyMap(m);
}
