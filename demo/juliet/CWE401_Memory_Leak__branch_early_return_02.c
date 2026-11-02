/* STATE A — un-annotated. The ownership axis default-reds the undeclared heap resource:
   UNKNOWN_RESOURCE (a generic boundary complaint, not yet a diagnosis of the leak). */
/* CWE: 401 Memory Leak (branch-conditional: leaks on an early-return path) */
#include <stdlib.h>

void CWE401_Memory_Leak__branch_early_return_02_bad(int c)
{
    char * data = (char *)malloc(100);
    if (data == NULL) { return; }
    /* POTENTIAL FLAW: early return on the c-path leaks data (never freed) */
    if (c) { return; }
    free(data);
}
