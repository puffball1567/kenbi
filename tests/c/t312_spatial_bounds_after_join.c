// @spatial
// BOUNDS ACROSS A SWITCH OR A LOOP. A bound checked before a `switch` or a loop holds after it
// only if it holds on every path through it: a case or an iteration that gives the index a new,
// unchecked value (or a `break` that leaves with one) loses it. Inside a loop, each iteration
// starts from what the previous one left, so a value replaced at the end of the body is
// unchecked at the top of the next. (The indices are unsigned, so only the upper bound is in
// question.)
#include <stdlib.h>
unsigned next_index(void);

// one case replaces the index
// @spatial
int after_switch(unsigned n, unsigned idx, int k) {
  /* @mem t::a { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < n) {
    switch (k) {
    case 1: idx = next_index(); break;
    default: break;
    }
    r = buf[idx];                               //EXPECT UNVALIDATED_INDEX
  }
  free(buf);
  return r;
}

// an iteration replaces the index
// @spatial
int after_loop(unsigned n, unsigned idx, int k) {
  /* @mem t::b { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < n) {
    for (int j = 0; j < k; j++) idx = next_index();
    r = buf[idx];                               //EXPECT UNVALIDATED_INDEX
  }
  free(buf);
  return r;
}

// the loop leaves through a `break` with a replaced index
// @spatial
int after_break(unsigned n, unsigned idx, int k) {
  /* @mem t::c { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < n) {
    while (k-- > 0) {
      if (k == 3) { idx = next_index(); break; }
    }
    r = buf[idx];                               //EXPECT UNVALIDATED_INDEX
  }
  free(buf);
  return r;
}

// the index is read, then replaced for the next iteration
// @spatial
int next_iteration(unsigned n, unsigned idx, int k) {
  /* @mem t::d { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < n) {
    for (int j = 0; j < k; j++) {
      r += buf[idx];                            //EXPECT UNVALIDATED_INDEX
      idx = next_index();
    }
  }
  free(buf);
  return r;
}

// a switch and a loop that leave the index alone keep its bound — clean
// @spatial
int untouched(unsigned n, unsigned idx, int k) {
  /* @mem t::e { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < n) {
    switch (k) {
    case 1: r = 1; break;
    default: r = 2; break;
    }
    for (int j = 0; j < k; j++) r += j;
    r += buf[idx];
  }
  free(buf);
  return r;
}

// a replaced index checked again before the next iteration uses it — clean
// @spatial
int rechecked(unsigned n, unsigned idx, int k) {
  /* @mem t::f { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (idx < n) {
    for (int j = 0; j < k; j++) {
      r += buf[idx];
      idx = next_index();
      if (idx >= n) break;
    }
  }
  free(buf);
  return r;
}

// the usual counted loop — clean
// @spatial
int counted(unsigned n) {
  /* @mem t::g { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  for (unsigned i = 0; i < n; i++) r += buf[i];
  free(buf);
  return r;
}
