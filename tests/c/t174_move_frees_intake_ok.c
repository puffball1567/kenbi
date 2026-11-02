#include <stdlib.h>
typedef struct { int x; } item_t;
// @moves(item)
void sink(item_t *item);
// @frees(item)
// @kenbi
void f(item_t *item) {   // f declares it takes ownership; the move to the sink discharges it
  sink(item);            // legit onward transfer — the @frees obligation is met by the move
}
