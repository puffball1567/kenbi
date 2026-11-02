#include <stdlib.h>
// @frees(p)
void dispose(void *p) {   // now the contract is written: information is sufficient
  free(p);
}
// With @frees declared, the same code as t86 becomes a CONFIDENT double free
// (asserted, not advisory): the annotation makes it 100%.
void f(int n) {
  /* @mem demo::buf { free: free, owner: p } */
  char *p = malloc(n);
  dispose(p);   // contract: frees p
  free(p);      // confident double free   //EXPECT DOUBLE_FREE
}
