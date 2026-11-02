#include <stdlib.h>
char *lookup(int);
void f(int n) {
  char *p = lookup(n);   // @nullable
  char c = *p;           // deref of possibly-null p   //EXPECT NULL_DEREF
  (void)c;
}
