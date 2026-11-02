// @kenbi
/* STATE C — the last use of `p` happens BEFORE the ownership handoff, so nothing touches the
   object after it is moved. GREEN. */
/* CWE: 672 Operation on a Resource after Release — fixed by using before the move. */
#include <stdlib.h>
typedef struct chan chan_t;
typedef struct { int x; } item_t;
// @borrows(q)
void use(item_t *q);
// @moves(item)
void chan_send(chan_t *c, item_t *item);

void CWE672_Use_After_Move__channel_send_01_fixed(chan_t *c)
{
    /* @mem demo::item { free: free, owner: p } */
    item_t *p = (item_t *)malloc(sizeof(item_t));
    if (p == NULL) { return; }
    use(p);            /* FIXED: use before the handoff */
    chan_send(c, p);
}
