// @kenbi
/* STATE C — the caller hands ownership to `consume` (which @frees it) and does NOT also free.
   The buffer is released exactly once. GREEN. This header is >6 lines so @kenbi binds FILE-LEVEL
   and covers both functions.
   CWE: 415 Double Free — fixed: the @frees side is the only side that frees.
   Padding line six. Padding line seven. */
#include <stdlib.h>
// @frees(p)
static void consume(char *p) { free(p); }

void CWE415_Double_Free__possible_handoff_54_fixed(int n)
{
    /* @mem g::buf { free: free, owner: p } */
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    consume(p);        /* FIXED: ownership handed off; caller does not free */
}
