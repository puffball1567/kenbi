// @kenbi
/* STATE C — the use happens BEFORE the free, so no access outlives the buffer. GREEN. */
/* CWE: 416 Use After Free — fixed by using before freeing. */
#include <stdlib.h>
// @borrows(line)
void printLine(const char * line);

void CWE416_Use_After_Free__alias_02_fixed()
{
    /* @mem g::buf { free: free, owner: data } */
    char * data = (char *)malloc(100);
    if (data == NULL) { exit(-1); }
    char * alias = data;
    /* FIXED: use before free */
    printLine(alias);
    free(data);
}
