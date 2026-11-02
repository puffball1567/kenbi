#include <stdlib.h>
// @frees(o)
void rel(char *o) {   //EXPECT CONTRACT_NOT_HONORED
  (void)o;   // declared @frees(o) but never frees o
}
