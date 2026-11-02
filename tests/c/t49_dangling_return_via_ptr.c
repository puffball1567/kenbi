#include <stdlib.h>
int *bad(void) {
  int x = 42;
  int *p = &x;   // p now points into a local
  return p;      // returning the alias dangles just the same   //EXPECT DANGLING_RETURN
}
