#include <stdlib.h>
char *lookup(int);
void f(int n) {
  char *p = lookup(n);   // @nullable
  if (p) {
    char c = *p;         // guarded by if(p) -> clean
    (void)c;
  }
}
