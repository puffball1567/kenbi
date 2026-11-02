#include <stdlib.h>
typedef struct { int x; } item_t;
void dispose(item_t *p) {   // same-file body visibly frees p, but declares no @frees
  free(p);                  //EXPECT UNCONTRACTED_RELEASE
}
// @moves(item)
void chan_send(item_t *item);
void f(void) {
  /* @mem demo::item { free: free, owner: p } */
  item_t *p = malloc(sizeof(item_t));
  dispose(p);        // uncontracted, but visibly frees p   //EXPECT UNCONTRACTED_ESCAPE
  chan_send(p);      // moves a maybe-freed pointer to the sink — possible use-after-free   //EXPECT POSSIBLE_USE_AFTER_FREE
}
