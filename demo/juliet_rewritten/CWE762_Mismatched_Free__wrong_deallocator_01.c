/* STATE C — the buffer is freed with its declared deallocator `g_free`, matching the contract.
   GREEN. */
/* CWE: 762 Mismatched Memory Management Routines — fixed by using the declared deallocator. */
#include <stdlib.h>
extern void g_free(void *p);

void CWE762_Mismatched_Free__wrong_deallocator_01_fixed(int n)
{
    /* @mem demo::buf { free: g_free, owner: p } */
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    g_free(p);   /* FIXED: the declared deallocator */
}
