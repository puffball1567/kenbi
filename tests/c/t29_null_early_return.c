#include <stdlib.h>
char *lookup(int);
void f(int n) {
  char *p = lookup(n);   // @nullable
  if (!p) return;
  char c = *p;           // p is non-null after the early return -> clean
  (void)c;
}
