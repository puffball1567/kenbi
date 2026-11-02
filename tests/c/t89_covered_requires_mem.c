#include <stdlib.h>
// Mandatory discipline: inside a covered function, an allocation without a resource
// declaration is RED (you must declare intent even for the obvious case). Outside
// covered scope it would be a non-gating advisory, dropped.
// @kenbi
void f(int n) {
  char *p = malloc(n);   // no resource declaration in covered scope -> RED   //EXPECT UNKNOWN_RESOURCE
  free(p);
}
