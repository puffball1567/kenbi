#include <stdlib.h>
char *lookup(int);
void f(int n) {
  char *p = lookup(n);   // @nullable
  if (p) {}              // narrows only inside; after the join p is still maybe-null
  char c = *p;           // NULL_DEREF (sound merge)   //EXPECT NULL_DEREF
  (void)c;
}
