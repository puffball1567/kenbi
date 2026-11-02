// @kenbi
/* STATE C — the buffer is freed EXACTLY once on every path (the c-path returns after freeing).
   GREEN. */
/* CWE: 415 Double Free — fixed by freeing once per path. */
#include <stdlib.h>

void CWE415_Double_Free__conditional_02_fixed(int c)
{
    /* @mem g::buf { free: free, owner: data } */
    char * data = (char *)malloc(100);
    if (data == NULL) { exit(-1); }
    /* FIXED: return after the conditional free so the tail free runs only otherwise */
    if (c) { free(data); return; }
    free(data);
}
