// @kenbi
/* STATE B — honestly annotated (the boundary is still here). The buffer is a @mem resource owned
   by `buf`. It is stored through `*slot` — a raw location kenbi cannot follow — so even with
   ownership declared, its release is unverifiable from here: ESCAPE_UNCHECKED. The honest contract
   pins the boundary onto the store; it does not annotate the boundary away. This header is >6 lines
   so @kenbi binds FILE-LEVEL and covers the function.
   CWE: 401 Memory Leak (ownership stored where kenbi cannot follow it). */
#include <stdlib.h>

void CWE401_Memory_Leak__escape_handoff_32_bad(char **slot, int n)
{
    /* @mem g::buf { free: free, owner: buf } */
    char *buf = (char *)malloc(n);
    if (buf == NULL) { return; }
    *slot = buf;          /* ESCAPE_UNCHECKED: stored where kenbi cannot follow */
}
