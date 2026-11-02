#include <stdlib.h>
typedef struct chan chan_t;
typedef struct { int x; } item_t;
void use(item_t *q);
// @moves(item)
void chan_send(chan_t *c, item_t *item);
void f(chan_t *c) {
  /* @mem demo::item { free: free, owner: p } */
  item_t *p = malloc(sizeof(item_t));
  chan_send(c, p);          // ownership moves to the receiver (channel handoff)
  use(p);                   // use after handoff -> use-after-move   //EXPECT USE_AFTER_MOVE
}
