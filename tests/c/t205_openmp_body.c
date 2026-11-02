//ARGS -fopenmp
#include <stdlib.h>
// A PARALLEL LOOP IS STILL A LOOP. Compiled with `-fopenmp` — how every project that uses
// OpenMP actually builds — libclang attaches the loop to an OMP directive cursor whose only
// children are the captured variable references: the walk never reaches the body, so every
// allocation and release inside a `#pragma omp parallel for` disappeared from the IR and the
// file came back GREEN. The directive is now blanked out of an in-memory copy before the parse
// (byte for byte, so lines and columns still point at the real file) and the body lowers like
// any other loop. Ownership reads the same either way: a release that conflicts across
// iterations conflicts whether those iterations run in sequence or all at once.

// @borrows(s)
void use(char *s);

// the shared pointer is released once per iteration, then once more after the loop
static void freed_in_parallel_loop(int n) {
  /* @mem t::a { free: free, owner: p } */
  char *p = malloc(8);
  #pragma omp parallel for
  for (int i = 0; i < n; i++) {
    free(p);   //EXPECT DOUBLE_FREE
  }
  free(p);   //EXPECT DOUBLE_FREE
}

// an allocation made inside the body and never released is a leak, not silence
static void leaks_in_parallel_loop(int n) {
  for (int i = 0; i < n; i++) {
    /* @mem t::b { free: free, owner: q } */
    #pragma omp parallel for
    for (int j = 0; j < n; j++) {
      char *q = malloc(8);   //EXPECT LEAK
      use(q);
    }
  }
}

// a directive spread over continuation lines is one logical directive
static void continued_directive(int n) {
  /* @mem t::c { free: free, owner: r } */
  char *r = malloc(8);
  #pragma omp parallel for \
          schedule(static)
  for (int i = 0; i < n; i++)
    use(r);
  free(r);
}

// per-iteration ownership, acquired and released inside the body -> clean
static void balanced_in_body(int n) {
  #pragma omp parallel for
  for (int i = 0; i < n; i++) {
    /* @mem t::d { free: free, owner: s } */
    char *s = malloc(8);
    use(s);
    free(s);
  }
}
