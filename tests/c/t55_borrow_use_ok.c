#include <stdlib.h>
// @borrows(q)
void sink(char *q);
// @borrows(p)
void use(char *p) {
  sink(p);   // lending it on to another borrower is fine — not a leak, not a free
}
