#include <stdlib.h>
char *lookup(int);
void f(int n) {
  char *p = lookup(n);   // @nullable
  if (p != NULL) {
    char c = *p;         // guarded by p != NULL -> clean
    (void)c;
  }
}
