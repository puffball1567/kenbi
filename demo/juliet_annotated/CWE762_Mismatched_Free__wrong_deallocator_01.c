/* STATE B — honestly annotated: the buffer is declared to be freed with `g_free` (its owner is
   `p`). But the code frees it with `free`, not the declared deallocator, so the reason converges
   to WRONG_DEALLOCATOR. You cannot annotate your way out. */
/* CWE: 762 Mismatched Memory Management Routines */
#include <stdlib.h>
extern void g_free(void *p);

void CWE762_Mismatched_Free__wrong_deallocator_01_bad(int n)
{
    /* @mem demo::buf { free: g_free, owner: p } */
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    /* POTENTIAL FLAW: declared g_free, but freed with free */
    free(p);
}
