/* STATE A — un-annotated. `chan_send` is an uncontracted boundary the owned pointer escapes to,
   so the ownership axis default-reds it generically: UNCONTRACTED_ESCAPE (not yet a move-use
   diagnosis). */
/* CWE: 672 Operation on a Resource after Expiration or Release (use after move) */
#include <stdlib.h>
typedef struct chan chan_t;
typedef struct { int x; } item_t;
void use(item_t *q);
void chan_send(chan_t *c, item_t *item);

void CWE672_Use_After_Move__channel_send_01_bad(chan_t *c)
{
    item_t *p = (item_t *)malloc(sizeof(item_t));
    if (p == NULL) { return; }
    chan_send(c, p);
    use(p);
}
