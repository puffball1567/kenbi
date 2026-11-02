/* STATE A — un-annotated. UNKNOWN_RESOURCE (generic). */
/* CWE: 416 Use After Free (through an alias) */
#include <stdlib.h>
void printLine(const char * line);

void CWE416_Use_After_Free__alias_02_bad()
{
    char * data = (char *)malloc(100);
    if (data == NULL) { exit(-1); }
    char * alias = data;
    free(data);
    /* POTENTIAL FLAW: use of `alias`, which points at the freed buffer */
    printLine(alias);
}
