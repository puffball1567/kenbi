// @spatial
// SPATIAL compound loop condition: `for (; i < n && s[i] != 0; i++)` is the canonical
// parser scan loop. The `i < n` bound must still be extracted from the `&&` condition
// (exactly as an if-guard would), otherwise every such loop floods with false reds.
// Regression for the jsmn pilot finding.
#include <stdlib.h>

extern int table[64];

// `&&` loop cond over a fixed array — the i < 64 conjunct bounds the body.
void scan_fixed(void) {
  for (int i = 0; i < 64 && table[i] != 0; i++) {
    table[i] = 0;                    // validated by the i < 64 conjunct
  }
}

// `&&` loop cond over a heap buffer sized by the same identifier.
void scan_heap(int n) {
  /* @mem demo::a { free: free, owner: a } */
  char *a = malloc(n);
  for (int i = 0; i < n && a[i] != '\0'; i++) {
    a[i] = 1;                        // validated by the i < n conjunct
  }
  free(a);
}
