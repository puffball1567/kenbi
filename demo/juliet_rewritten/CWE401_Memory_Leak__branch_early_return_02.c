// @kenbi
/* STATE C — the leak is gone: the free obligation is discharged on EVERY path (the c-path frees
   before returning). kenbi confirms the function is safe. GREEN. */
/* CWE: 401 Memory Leak — fixed by freeing on all paths. */
#include <stdlib.h>

void CWE401_Memory_Leak__branch_early_return_02_fixed(int c)
{
    /* @mem g::buf { free: free, owner: data } */
    char * data = (char *)malloc(100);
    if (data == NULL) { return; }
    /* FIXED: free on the early-return path too */
    if (c) { free(data); return; }
    free(data);
}
