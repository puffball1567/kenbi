#include <stdlib.h>
int *ok(void) {
  static int x = 42;
  return &x;     // static storage outlives the call — safe, no false positive
}
