#include <stdlib.h>
char *bad(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  free(p);
  return p;      // returns a freed pointer — caller holds a dangling reference   //EXPECT DANGLING_RETURN
}
