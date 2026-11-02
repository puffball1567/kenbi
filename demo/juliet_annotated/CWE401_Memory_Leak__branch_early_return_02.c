// @kenbi
/* STATE B — honestly annotated (the bug is still here). `data` is a heap resource freed with
   free(). The c-path returns WITHOUT discharging the free obligation, so the reason converges
   from the generic UNKNOWN_RESOURCE to the true class: LEAK. You cannot annotate your way out. */
/* CWE: 401 Memory Leak (branch-conditional: leaks on an early-return path) */
#include <stdlib.h>

void CWE401_Memory_Leak__branch_early_return_02_bad(int c)
{
    /* @mem g::buf { free: free, owner: data } */
    char * data = (char *)malloc(100);
    if (data == NULL) { return; }
    /* POTENTIAL FLAW: early return on the c-path leaks data */
    if (c) { return; }
    free(data);
}
