#include <stdlib.h>
char *lookup(int);
void f(int n) {
  char *p = lookup(n);   // @nullable
  char c = *p;           // deref BEFORE any check   //EXPECT NULL_DEREF
  if (p) {}
  (void)c;
}
