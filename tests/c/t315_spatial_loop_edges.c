// @spatial
// WHERE A LOOP'S CONDITION HOLDS. A `do … while (c)` tests after the body, so its first
// iteration runs without the bound. A `continue` in a `for` still runs the increment. And a
// statement's own accesses read a variable as it was before the statement assigns it.
#include <stdlib.h>
unsigned next_index(void);

// the first iteration of a do-while is not covered by its condition
// @spatial
int do_while_first(unsigned n, unsigned i) {
  /* @mem t::a { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  do {
    r += buf[i];                                //EXPECT UNVALIDATED_INDEX
    i = next_index();
  } while (i < n);
  free(buf);
  return r;
}

// `continue` goes through the increment: the index is stepped past its check
// @spatial
int continue_steps(unsigned i, int k) {
  int tab[8];
  int r = 0;
  for (unsigned j = 0; j < 8; j++) tab[j] = 0;
  if (i < 8) {
    for (;; i++) {
      r += tab[i];                              //EXPECT UNVALIDATED_INDEX
      if (r > k) break;
      continue;
    }
  }
  return r;
}

// the right-hand side indexes with the value from before the assignment
// @spatial
int assigned_from_itself(unsigned i) {
  int tab[8];
  for (unsigned j = 0; j < 8; j++) tab[j] = 0;
  i = tab[i] % 8;                               //EXPECT UNVALIDATED_INDEX
  return (int)i;
}

// checked before the body, re-checked by the condition — clean
// @spatial
int loop_edges_ok(unsigned n, unsigned i, int k) {
  /* @mem t::b { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (i < n) {
    do {
      r += buf[i];
      i = next_index();
    } while (i < n);
  }
  for (unsigned j = 0; j < n; j++) {
    if (j == (unsigned)k) continue;
    r += buf[j];
  }
  free(buf);
  return r;
}
