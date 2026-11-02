#include <stdlib.h>
typedef struct { int x; } item_t;
// @moves(item)
void sink(item_t *item);
// @borrows(item)
// @kenbi
void f(item_t *item) {
  sink(item);   // moves a pointer we only borrow — hands ownership we don't have   //EXPECT BORROW_MOVED
}
