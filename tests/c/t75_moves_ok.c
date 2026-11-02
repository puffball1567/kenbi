#include <stdlib.h>
typedef struct chan chan_t;
typedef struct { int x; } item_t;
// @moves(item)
void chan_send(chan_t *c, item_t *item);
void f(chan_t *c) {
  /* @mem demo::item { free: free, owner: p } */
  item_t *p = malloc(sizeof(item_t));
  chan_send(c, p);          // moved -> not a leak, not used afterwards -> clean
}
