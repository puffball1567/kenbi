// @kenbi
/* STATE B — honestly annotated: `data` is a heap resource freed with free(). On the c-path it
   is freed twice, so the reason converges to DOUBLE_FREE. You cannot annotate your way out. */
/* CWE: 415 Double Free (branch-conditional) */
#include <stdlib.h>

void CWE415_Double_Free__conditional_02_bad(int c)
{
    /* @mem g::buf { free: free, owner: data } */
    char * data = (char *)malloc(100);
    if (data == NULL) { exit(-1); }
    if (c) { free(data); }
    /* POTENTIAL FLAW: double free on the c-path */
    free(data);
}
