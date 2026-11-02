#include <stdlib.h>
// @owns(ret)
char *make_buf(int n);
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = make_buf(n);   // owns the result -> a free-once obligation   //EXPECT LEAK
  (void)p;                 // never freed -> LEAK
}
