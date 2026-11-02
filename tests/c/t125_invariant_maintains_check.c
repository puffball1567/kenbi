// @spatial
// INVARIANT slice 3 — the @maintains preservation check. A write annotated `@maintains`
// is VERIFIED to actually preserve the invariant, not trusted. An increment by δ keeps
// `field <= size` only if `field <= size - δ` holds first (a guard establishes it); an
// unguarded increment can exceed the bound -> INVARIANT_NOT_MAINTAINED (the claim is a
// lie). A decrement always preserves an upper bound.
#include <stddef.h>

struct Pool { int count; };

// Guarded increment: the `count >= cap` guard gives `count < cap`, so `count++` keeps
// `count <= cap` — the @maintains claim is verified, clean. (The jsmn alloc_token shape.)
// @invariant(p->count <= cap)
void grow_ok(struct Pool *p, int cap) {
  if (p->count >= cap) {
    return;
  }
  p->count++;                        // @maintains(p->count <= cap)
}

// Unguarded increment claiming @maintains: nothing bounds count below cap first, so the
// increment can break the invariant — the claim is a lie.
// @invariant(p->count <= cap)
void grow_lie(struct Pool *p, int cap) {
  p->count++;                        // @maintains(p->count <= cap)  //EXPECT INVARIANT_NOT_MAINTAINED
}

// `+= 2` needs `count <= cap - 2` first; a guard giving only `count < cap` is not enough.
// @invariant(p->count <= cap)
void grow_by_two_lie(struct Pool *p, int cap) {
  if (p->count >= cap) {
    return;
  }
  p->count += 2;                     // @maintains(p->count <= cap)  //EXPECT INVARIANT_NOT_MAINTAINED
}

// A decrement preserves an upper bound unconditionally — clean.
// @invariant(p->count <= cap)
void shrink_ok(struct Pool *p, int cap) {
  p->count--;                        // @maintains(p->count <= cap)
}
