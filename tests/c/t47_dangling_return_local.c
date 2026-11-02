#include <stdlib.h>
int *bad(void) {
  int x = 42;
  return &x;     // address of a local — dangles once the frame is gone   //EXPECT DANGLING_RETURN
}
