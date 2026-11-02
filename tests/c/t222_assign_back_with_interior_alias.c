#include <stdlib.h>
// `p = destroy(p)` — a release DECLARED to hand back NULL — leaves p owning nothing, and
// returning p afterwards returns NULL, not a dangling pointer. kenbi normally expresses that by
// DROPPING the freed origin at the join: once the handle no longer names it and nothing else
// does, an origin that can be neither used nor released again carries no hazard.
//
// It stops being droppable the moment some OTHER handle still names it — an INTERIOR alias
// (`cs = base + i`), which must keep it alive so a use through `cs` after the release is still a
// use-after-free. The join then holds the origin OWNED (the path that did not release) and FREED
// (the path that did) at once, and a `return base` read that as returning a freed pointer AND
// left the owned half undischarged: one false DANGLING_RETURN and one false LEAK from code that
// is correct. MagickCore's `GetImageStatistics` is written exactly this way.
//
// The pairing is now recorded: the handle the NULL-returning release nulled is known, so the
// freed half is understood as "NULL on that path" and the owned half transfers out.

// @allocator t::fam { alloc: acq, free: pf, free_returns_null: rel }
void *acq(unsigned long n, unsigned long s);
void pf(void *p);
void *rel(void *p);
typedef struct { double m; } Stat;
int cond(void);

// GREEN: the interior alias is taken, the release nulls the handle on one path, and the result
// is returned — NULL on that path, the owned block on the other.
// @kenbi
// @owns
Stat *interior_then_conditional_release(int n) {
  Stat *base = (Stat *) acq(n, sizeof(Stat));
  Stat *cs = base + 1;
  cs->m = 0.0;
  if (cond() != 0)
    base = (Stat *) rel(base);
  return base;
}

// RED: a PLAIN release does not null the handle, so returning it hands out a freed pointer.
// @kenbi
// @owns
Stat *plain_release_then_return(int n) {
  Stat *base = (Stat *) acq(n, sizeof(Stat));   //EXPECT LEAK
  Stat *cs = base + 1;
  cs->m = 0.0;
  if (cond() != 0)
    pf(base);
  return base;   //EXPECT DANGLING_RETURN
}

// RED: the interior alias is USED after the release — still a use-after-free. The pairing
// exempts the RETURN of the nulled handle, nothing else.
// @kenbi
void interior_used_after_release(int n) {
  Stat *base = (Stat *) acq(n, sizeof(Stat));
  Stat *cs = base + 1;
  base = (Stat *) rel(base);
  cs->m = 0.0;   //EXPECT USE_AFTER_FREE
}

// RED: a conditional release with NO transfer out still leaks on the path that did not release.
// @kenbi
void conditional_release_no_return(int n) {
  Stat *base = (Stat *) acq(n, sizeof(Stat));   //EXPECT LEAK
  Stat *cs = base + 1;
  cs->m = 0.0;
  if (cond() != 0)
    base = (Stat *) rel(base);
}
