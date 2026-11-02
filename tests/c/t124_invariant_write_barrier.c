// @spatial
// INVARIANT write-barrier (slice 2): a field declared under `@invariant` is PROTECTED —
// every write to it must declare its effect (`@maintains`) or it is UNGUARDED_INVARIANT_
// WRITE. This is what makes the invariant trustworthy: a write that could break it cannot
// slip past unaccounted. (No green payoff yet — the access side is a later slice; this
// slice only adds the red discipline, so it cannot create a false green.)
#include <stddef.h>

struct Pool { int count; };

// An unannotated write to a protected field — flagged.
// @invariant(p->count <= cap)
void grow_unguarded(struct Pool *p, int cap) {
  p->count++;                        //EXPECT UNGUARDED_INVARIANT_WRITE
}

// The same write, declared to preserve the invariant — accepted (preservation check is a
// later slice; for now the declaration discharges the write-barrier).
// @invariant(p->count <= cap)
void grow_guarded(struct Pool *p, int cap) {
  if (p->count >= cap) {
    return;
  }
  p->count++;                        // @maintains(p->count <= cap)
}

// A plain assignment to a protected field, unannotated — also flagged.
// @invariant(p->count <= cap)
void reset_unguarded(struct Pool *p, int cap) {
  p->count = cap + 1;                //EXPECT UNGUARDED_INVARIANT_WRITE
}

// A write to a DIFFERENT field is not protected — no finding.
struct Pool2 { int count; int other; };
// @invariant(p->count <= cap)
void touch_other(struct Pool2 *p, int cap) {
  p->other = 99;                     // not the protected field — clean
}
