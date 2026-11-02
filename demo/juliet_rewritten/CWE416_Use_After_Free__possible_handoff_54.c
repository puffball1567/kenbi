// @kenbi
/* STATE C — the caller USES the buffer while it is still live, THEN hands it to `release` (which
   @frees it). The buffer is never touched after it is freed. GREEN. This header is >6 lines so
   @kenbi binds FILE-LEVEL and covers both functions.
   CWE: 416 Use After Free — fixed: use precedes the hand-off that frees.
   Padding line seven. */
#include <stdlib.h>
// @frees(p)
static void release(char *p) { free(p); }

void CWE416_Use_After_Free__possible_handoff_54_fixed(int n)
{
    /* @mem g::buf { free: free, owner: p } */
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    p[0] = 'x';        /* FIXED: the use comes before the hand-off */
    release(p);
}
