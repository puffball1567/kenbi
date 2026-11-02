#include <stdlib.h>
void consume(void *p);
void sink(void *p);
void f(int n, int c, int d) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);   //EXPECT LEAK
  if (c) {
    if (d) {
      free(p);
    }
  }
}
