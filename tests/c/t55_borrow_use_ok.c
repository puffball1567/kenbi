#include <stdlib.h>
void sink(char *q);
// @borrows(p)
void use(char *p) {
  sink(p);   // borrowing onward is fine — not a leak, not a free
}
