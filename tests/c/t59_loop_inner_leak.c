#include <stdlib.h>
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  for (int i = 0; i < n; i++) {
    char *p = malloc(16);   // allocated every iteration, never freed -> leak   //EXPECT LEAK
    (void)p;
  }
}
