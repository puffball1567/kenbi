#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  for (int i = 0; i < n; i++) {
    char *p = malloc(16);
    free(p);
    free(p);                // double free within a single iteration -> caught   //EXPECT DOUBLE_FREE
  }
}
