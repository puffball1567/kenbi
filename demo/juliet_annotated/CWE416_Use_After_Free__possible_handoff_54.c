// @kenbi
/* STATE B — honestly annotated: `release` @frees its argument (takes ownership, releases once).
   The caller then USES `p`, so with the hand-off declared kenbi proves the buffer is touched after
   it was freed: the POSSIBLE hint becomes a confident USE_AFTER_FREE. This header is >6 lines so
   @kenbi binds FILE-LEVEL and covers both functions.
   CWE: 416 Use After Free (a @frees hand-off then a use). */
#include <stdlib.h>
// @frees(p)
static void release(char *p) { free(p); }

void CWE416_Use_After_Free__possible_handoff_54_bad(int n)
{
    /* @mem g::buf { free: free, owner: p } */
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    release(p);        /* @frees: release takes ownership and frees */
    p[0] = 'x';        /* USE_AFTER_FREE: p is touched after release freed it */
}
