#include <stdlib.h>
// @borrows(s)
char *first(char *s) {
  return s;   // returning a borrowed pointer is a passthrough — allowed, no leak
}
