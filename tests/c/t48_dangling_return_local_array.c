#include <stdlib.h>
char *bad(void) {
  char buf[64];
  return buf;    // a local array name decays to a stack pointer — dangles   //EXPECT DANGLING_RETURN
}
