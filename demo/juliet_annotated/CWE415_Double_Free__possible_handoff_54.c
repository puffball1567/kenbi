// @kenbi
/* STATE B — honestly annotated: `consume` @frees its argument (takes ownership, releases once).
   The caller ALSO frees `p`, so with the hand-off declared kenbi proves it is released twice:
   the POSSIBLE hint becomes a confident DOUBLE_FREE. The annotation exposes the bug, it does not
   hide it. This header is >6 lines so @kenbi binds FILE-LEVEL and covers both functions.
   CWE: 415 Double Free (a @frees hand-off plus a caller free). */
#include <stdlib.h>
// @frees(p)
static void consume(char *p) { free(p); }

void CWE415_Double_Free__possible_handoff_54_bad(int n)
{
    /* @mem g::buf { free: free, owner: p } */
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    consume(p);        /* @frees: consume takes ownership and frees */
    free(p);           /* DOUBLE_FREE: caller frees the already-freed buffer */
}
