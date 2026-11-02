#include <stdlib.h>
// INTERIOR-NESS IS A MAY-FACT. Advancing a handle off the start of its block (`p += k`, `p++`)
// makes releasing it FREE_INTERIOR (CWE-761) — and a handle advanced on EITHER incoming path is
// advanced after the join, because the path that advanced it is one the program can take.
//
// The binding join kept only the CURRENT path's interior flag, so a branch that advanced the
// pointer and then fell through to a shared release was silent: `if (c) p += 8;  free(p);`
// passed as GREEN. The mirror form (`else p += 8;`) was caught, purely because the else path is
// the one the join happens to be standing on — the asymmetry is what gives it away.

// @allocator t::fam { alloc: acq, free: pf }
void *acq(unsigned long n, unsigned long s);
void pf(void *p);
int cond(void);

// RED: advanced on the THEN path only.
// @kenbi
void then_only(void) {
  double *p = (double *) acq(16, sizeof(double));   //EXPECT LEAK
  if (cond())
    p += 8;
  pf(p);   //EXPECT FREE_INTERIOR
}

// RED: advanced on the ELSE path only.
// @kenbi
void else_only(void) {
  double *p = (double *) acq(16, sizeof(double));   //EXPECT LEAK
  if (cond()) { } else p += 8;
  pf(p);   //EXPECT FREE_INTERIOR
}

// RED: advanced unconditionally — the control that always worked.
// @kenbi
void always(void) {
  double *p = (double *) acq(16, sizeof(double));   //EXPECT LEAK
  p += 8;
  pf(p);   //EXPECT FREE_INTERIOR
}

// GREEN: never advanced — the join must not invent interior-ness either.
// @kenbi
void never(void) {
  double *p = (double *) acq(16, sizeof(double));
  if (cond())
    p[0] = 1.0;
  pf(p);
}
