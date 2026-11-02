#include <stdlib.h>
void g_free(void *p);
void f(int n) {
  /* @mem demo::buf { free: g_free, owner: p } */
  char *p = malloc(n);
  free(p);            // declared g_free, freed with free   //EXPECT WRONG_DEALLOCATOR
}
