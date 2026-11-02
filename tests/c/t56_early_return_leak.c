#include <stdlib.h>
void f(int err) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(16);   //EXPECT LEAK
  if (err) {
    return;        // abandons p on the error path — leak (every exit must dispose)
  }
  free(p);
}
