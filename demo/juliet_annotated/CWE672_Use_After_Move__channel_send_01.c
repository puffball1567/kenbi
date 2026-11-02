// @kenbi
/* STATE B — honestly annotated: `chan_send` @moves its item (ownership passes to the receiver),
   and the buffer is owned by `p`. Using `p` after the handoff is a use-after-move — the reason
   converges to USE_AFTER_MOVE. You cannot annotate your way out. */
/* CWE: 672 Operation on a Resource after Expiration or Release (use after move) */
#include <stdlib.h>
typedef struct chan chan_t;
typedef struct { int x; } item_t;
// @borrows(q)
void use(item_t *q);
// @moves(item)
void chan_send(chan_t *c, item_t *item);

void CWE672_Use_After_Move__channel_send_01_bad(chan_t *c)
{
    /* @mem demo::item { free: free, owner: p } */
    item_t *p = (item_t *)malloc(sizeof(item_t));
    if (p == NULL) { return; }
    chan_send(c, p);
    /* POTENTIAL FLAW: p was moved to the receiver */
    use(p);
}
