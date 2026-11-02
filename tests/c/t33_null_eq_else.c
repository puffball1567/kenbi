#include <stdlib.h>
char *lookup(int);
void f(int n) {
  char *p = lookup(n);   // @nullable
  if (p == NULL) {
    return;
  } else {
    char c = *p;         // else of (p==NULL): p is non-null -> clean
    (void)c;
  }
}
