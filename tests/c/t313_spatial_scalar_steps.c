// @spatial
// IN-PLACE CHANGES OF AN INDEX. `i++`, `--i`, `i += k` and `i = i ± k` move the value, and a
// bound checked before the change moves with it: after `if (i < n) i++;` the value is only
// known `< n + 1`. A step keeps a bound only where it cannot wrap — stepping up needs an upper
// bound, stepping down a lower one (for an unsigned value, at least the size of the step).
#include <stdlib.h>

// checked, then stepped past the check
// @spatial
int step_after_check(unsigned n, unsigned i) {
  /* @mem t::a { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (i < n) {
    i++;
    r = buf[i];                                 //EXPECT INAPPROPRIATE_BOUND
  }
  free(buf);
  return r;
}

// the same through `+=` and through `i = i + 1`
// @spatial
int step_other_forms(unsigned i, unsigned j) {
  int tab[8];
  int r = 0;
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  if (i < 8) {
    i += 2;
    r += tab[i];                                //EXPECT INAPPROPRIATE_BOUND
  }
  if (j < 8) {
    j = j + 1;
    r += tab[j];                                //EXPECT INAPPROPRIATE_BOUND
  }
  return r;
}

// an unsigned value stepped down with nothing showing it is above zero wraps around
// @spatial
int step_down_unsigned(unsigned i) {
  int tab[8];
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  if (i < 8) {
    i--;
    return tab[i];                              //EXPECT UNVALIDATED_INDEX
  }
  return 0;
}

// a field is stepped like a variable
struct Cur { unsigned pos; };
// @spatial
int step_field(struct Cur *c) {
  int tab[8];
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  if (c->pos < 8) {
    c->pos++;
    return tab[c->pos];                         //EXPECT INAPPROPRIATE_BOUND
  }
  return 0;
}

// `&=` and `%=` bound the value to their constant — which must still cover the buffer
// @spatial
int mask_too_wide(unsigned i, unsigned j) {
  int tab[8];
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  i &= 0xff;
  j %= 16;
  return tab[i]                                 //EXPECT INAPPROPRIATE_BOUND
       + tab[j];                                //EXPECT INAPPROPRIATE_BOUND
}

// a step inside the subscript: `buf[i++]` reads the old value, `buf[++i]` the new one
// @spatial
int step_in_subscript(unsigned i, unsigned j) {
  int tab[8];
  int r = 0;
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  if (i < 8) {
    r += tab[i++];
    r += tab[i];                                //EXPECT INAPPROPRIATE_BOUND
  }
  if (j < 8) {
    r += tab[++j];                              //EXPECT INAPPROPRIATE_BOUND
  }
  return r;
}

// steps that stay inside the check — clean
// @spatial
int steps_ok(unsigned n, unsigned i, unsigned j, int m) {
  int tab[8];
  int r = 0;
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  for (unsigned k = 8; k > 0; k--) r += tab[k - 1];
  for (int k = 7; k >= 0; k--) r += tab[k];
  unsigned w = 0;
  while (w < 8) { r += tab[w]; w += 1; }
  if (i < 7) { i++; r += tab[i]; }
  if (j >= 1 && j < 8) { j--; r += tab[j]; }
  if (m >= 0 && m < 7) { m = m + 1; r += tab[m]; }
  if (n < 8) r += tab[n++];
  n &= 7;
  r += tab[n];
  return r;
}
