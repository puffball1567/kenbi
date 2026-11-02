#include <stdlib.h>
char *must(int);
void f(int n) {
  char *p = must(n);     // @nonnull
  char c = *p;           // asserted non-null -> clean
  (void)c;
}
