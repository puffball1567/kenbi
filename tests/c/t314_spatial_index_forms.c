// @spatial
// THE FORM OF AN INDEX. An index (or a length) is matched to a bound check by the variable it
// names: `i`, `i ± k`. A constant, `x % K` and `x & K` are bounded by their own form, and that
// bound is checked against the buffer like any other. An expression of any other form — a
// product, a call, two variables, a nested read — names nothing a check can be matched to, so
// it is reported: store it in a variable and bound that. `*(p + i)` is `p[i]`.
#include <stdlib.h>
#include <string.h>
unsigned pick(void);

// expressions no bound check can be matched to
// @spatial
int unreadable(unsigned n, unsigned i, unsigned *t) {
  /* @mem t::a { free: free, owner: buf } */
  int *buf = (int *)malloc(n * sizeof(int));
  int r = 0;
  if (i < n) {
    r += buf[i * 2];                            //EXPECT UNVALIDATED_INDEX
    r += buf[pick()];                           //EXPECT UNVALIDATED_INDEX
    r += buf[t[0]];                             //EXPECT UNVALIDATED_INDEX
    r += buf[i + i];                            //EXPECT UNVALIDATED_INDEX
  }
  free(buf);
  return r;
}

// a constant, a modulus and a mask that do not cover the array
// @spatial
int bounded_by_form(unsigned i, int s) {
  int tab[8];
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  int r = tab[8];                               //EXPECT INAPPROPRIATE_BOUND
  r += tab[i % 16];                             //EXPECT INAPPROPRIATE_BOUND
  r += tab[i & 15];                             //EXPECT INAPPROPRIATE_BOUND
  r += tab[s % 8];                              //EXPECT INDEX_MAYBE_NEGATIVE
  return r;
}

// pointer arithmetic is the same access
// @spatial
int through_pointer(unsigned i, unsigned j) {
  int tab[8];
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  int r = *(tab + i);                           //EXPECT UNVALIDATED_INDEX
  r += *(j + tab);                              //EXPECT UNVALIDATED_INDEX
  r += *(tab + 9);                              //EXPECT INAPPROPRIATE_BOUND
  return r;
}

// lengths: a constant too large for the destination, and one no check can be matched to
// @spatial
void lengths(const char *src, unsigned n) {
  char dst[8];
  memcpy(dst, src, 16);                         //EXPECT INAPPROPRIATE_BOUND
  memcpy(dst, src, n * 2);                      //EXPECT UNVALIDATED_SIZE
}

// the same forms, in range — clean
// @spatial
int forms_ok(unsigned n, unsigned i, const char *src) {
  int tab[8];
  char dst[8];
  for (unsigned k = 0; k < 8; k++) tab[k] = 0;
  int r = tab[7] + tab[i % 8] + tab[i & 7] + *(tab + 3);
  unsigned d = i * 2;
  if (d < 8) r += tab[d];
  if (n < 8) r += *(tab + n);
  memcpy(dst, src, sizeof(dst));
  memcpy(dst, src, 8);
  return r + dst[0];
}
