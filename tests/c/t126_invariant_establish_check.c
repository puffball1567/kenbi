// @spatial
// INVARIANT slice 4 — the init/establish check. A SET write `field = rhs` is the
// induction BASE CASE: it establishes `field REL size` directly from its RHS (unlike an
// increment, whose preservation rests on a prior guard). kenbi VERIFIES `rhs REL size` by
// a fixed vocabulary — a constant 0 into an UNSIGNED size (`0 <= size`), or the size
// itself / `size - k`. An unverifiable RHS is INVARIANT_NOT_MAINTAINED (declare-don't-
// infer: a set that cannot be shown to establish the invariant is never assumed to).
// This slice only adds RED — the access-side green is slice 5.
#include <stddef.h>

struct Pool { unsigned int count; };

// `count = 0` into an unsigned `cap`: `0 <= cap` holds (cap >= 0) — established, clean.
// @invariant(p->count <= cap)
void init_zero_ok(struct Pool *p, unsigned int cap) {
  p->count = 0;                      // @maintains(p->count <= cap)
}

// `count = cap`: `cap <= cap` holds — established, clean.
// @invariant(p->count <= cap)
void init_full_ok(struct Pool *p, unsigned int cap) {
  p->count = cap;                    // @maintains(p->count <= cap)
}

// `count = cap + 1`: `cap + 1 <= cap` is false — the set breaks the invariant.
// @invariant(p->count <= cap)
void init_overfull_lie(struct Pool *p, unsigned int cap) {
  p->count = cap + 1;                // @maintains(p->count <= cap)  //EXPECT INVARIANT_NOT_MAINTAINED
}

// `count = 0` but `cap` is SIGNED: `0 <= cap` is NOT provable (cap could be negative) —
// kenbi refuses to assume it.
struct PoolS { int count; };
// @invariant(p->count <= cap)
void init_zero_signed_lie(struct PoolS *p, int cap) {
  p->count = 0;                      // @maintains(p->count <= cap)  //EXPECT INVARIANT_NOT_MAINTAINED
}

// `count = other`: an unrelated variable kenbi cannot relate to `cap` — not established.
// @invariant(p->count <= cap)
void init_other_lie(struct Pool *p, unsigned int cap, unsigned int other) {
  p->count = other;                  // @maintains(p->count <= cap)  //EXPECT INVARIANT_NOT_MAINTAINED
}
