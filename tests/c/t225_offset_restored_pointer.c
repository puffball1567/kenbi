#include <stdlib.h>
// A HANDLE MOVED INTO THE MIDDLE OF ITS BLOCK CAN BE MOVED BACK. Image and signal code centres a
// buffer so it can be indexed with negative offsets — MagickCore's segment.c writes
//
//     squares=AcquireQuantumMemory(513,…);  squares+=255;
//     for (i=-255; i<=255; i++) squares[i]=i*i;   …   squares-=255;  Relinquish(squares);
//
// kenbi tracked the advance — the handle becomes INTERIOR, so releasing it is FREE_INTERIOR —
// but not the retreat, so the restored handle stayed interior for good and the block, never
// discharged, also read as a LEAK. Two findings on correct code.
//
// The handle now carries a CONSTANT offset PER PATH, merged at every join by a flat lattice
// (equal -> that value, anything else -> unknown). `interiorVar` stays the may-fact gate and is
// never cleared; the offset can only ACQUIT it, and only when this path proves the handle is
// back at 0. A running total kept outside the join would add up `if (c) p += 8; else p -= 8;`
// and call it 0 on both branches — the case below exists because an earlier attempt did.
//
// Only a SELF-advance is folded. `q = p.get()` and friends are interior with no offset given,
// and "not given" must not read as "at the start".

// @allocator t::fam { alloc: acq, free: pf }
void *acq(unsigned long n, unsigned long s);
void pf(void *p);
int cond(void);

// GREEN: advanced and moved back, released at the start.
// @kenbi
void centred_buffer(void) {
  double *sq = (double *) acq(513, sizeof(double));
  int i;
  sq += 255;
  for (i = -255; i <= 255; i++)
    sq[i] = (double) i;
  sq -= 255;
  pf(sq);
}

// GREEN: `++` / `--` balance too.
// @kenbi
void incdec_balanced(void) {
  double *p = (double *) acq(4, sizeof(double));
  p++;
  p--;
  pf(p);
}

// RED: +8 on one path and -8 on the other is not 0 on either of them.
// @kenbi
void branches_disagree(void) {
  double *p = (double *) acq(16, sizeof(double));   //EXPECT LEAK
  if (cond()) p += 8; else p -= 8;
  pf(p);   //EXPECT FREE_INTERIOR
}

// RED: advanced on one branch only.
// @kenbi
void then_only(void) {
  double *p = (double *) acq(16, sizeof(double));   //EXPECT LEAK
  if (cond()) p += 8;
  pf(p);   //EXPECT FREE_INTERIOR
}

// RED: moved back only part of the way.
// @kenbi
void partly_restored(void) {
  double *p = (double *) acq(513, sizeof(double));   //EXPECT LEAK
  p += 255;
  p -= 100;
  pf(p);   //EXPECT FREE_INTERIOR
}

// RED: the steps are not constants, so kenbi cannot show they cancel — it does not guess.
// @kenbi
void variable_steps(int n) {
  double *p = (double *) acq(513, sizeof(double));   //EXPECT LEAK
  p += n;
  p -= n;
  pf(p);   //EXPECT FREE_INTERIOR
}

// RED: advanced an unknown number of times.
// @kenbi
void advanced_in_loop(int n) {
  double *p = (double *) acq(64, sizeof(double));   //EXPECT LEAK
  int i;
  for (i = 0; i < n; i++)
    p++;
  pf(p);   //EXPECT FREE_INTERIOR
}
