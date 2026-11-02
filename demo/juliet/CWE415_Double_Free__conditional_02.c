/* STATE A — un-annotated. UNKNOWN_RESOURCE (generic). */
/* CWE: 415 Double Free (branch-conditional) */
#include <stdlib.h>

void CWE415_Double_Free__conditional_02_bad(int c)
{
    char * data = (char *)malloc(100);
    if (data == NULL) { exit(-1); }
    if (c) { free(data); }
    /* POTENTIAL FLAW: on the c-path data was already freed above */
    free(data);
}
