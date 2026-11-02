#include <stdlib.h>
// @borrows(p)
void consume(char *p) {
  free(p);   // p is only borrowed — freeing it is the owner's job   //EXPECT BORROW_FREED
}
