/* STATE A — un-annotated. The heap resource is undeclared, so the ownership axis default-reds
   it generically: UNKNOWN_RESOURCE (not yet a diagnosis of the deallocator mismatch). */
/* CWE: 762 Mismatched Memory Management Routines */
#include <stdlib.h>
extern void g_free(void *p);

void CWE762_Mismatched_Free__wrong_deallocator_01_bad(int n)
{
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    free(p);
}
