#include <stdlib.h>
// @frees(o)
void rel(char *o) {
  free(o);   // honors the contract -> clean
}
