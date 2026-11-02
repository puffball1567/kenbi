// @kenbi
/* STATE B — honestly annotated: `consume` @frees its argument (takes ownership and releases it
   once), and the buffer is owned by `p`. The caller ALSO frees `p`, so it is released twice
   across two functions — the reason converges to DOUBLE_FREE, provable ONLY because the handoff
   is declared (an annotation-free checker cannot see across the boundary). This header is >6
   lines so @kenbi binds FILE-LEVEL and covers both functions.
   CWE: 415 Double Free (a @frees handoff plus a caller free). */
#include <stdlib.h>
// @frees(p)
static void consume(char *p) { free(p); }

void CWE415_Double_Free__frees_handoff_03_bad(int n)
{
    /* @mem g::buf { free: free, owner: p } */
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    free(p);           /* POTENTIAL FLAW: caller frees ... */
    consume(p);        /* ... and consume() frees again */
}
