#include <stdlib.h>
typedef struct chan chan_t;
typedef struct { int x; } item_t;
// @moves(item)
void chan_send(chan_t *c, item_t *item);
// @kenbi
item_t *f(chan_t *c) {
  /* @mem demo::item { free: free, owner: p } */
  item_t *p = malloc(sizeof(item_t));
  chan_send(c, p);   // ownership moves to the receiver (channel handoff)
  return p;          // returns a moved-out pointer — the caller gets a dangling handle   //EXPECT DANGLING_RETURN
}
