#include <stdlib.h>
typedef struct { int x; } item_t;
// @moves(item)
void sink(item_t *item);
// @kenbi
void f(item_t *item) {   // uncontracted pointer param — f never declared it owns item
  sink(item);            // hands ownership to a @moves sink with no intake contract   //EXPECT UNCONTRACTED_MOVE
}
