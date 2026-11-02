// @kenbi
/* STATE B — honestly annotated: printLine borrows its argument, `data` is a heap resource freed
   with free(). `alias` aliases `data`; using it after free(data) is a use-after-free — the
   reason converges to USE_AFTER_FREE. You cannot annotate your way out. */
/* CWE: 416 Use After Free (through an alias) */
#include <stdlib.h>
// @borrows(line)
void printLine(const char * line);

void CWE416_Use_After_Free__alias_02_bad()
{
    /* @mem g::buf { free: free, owner: data } */
    char * data = (char *)malloc(100);
    if (data == NULL) { exit(-1); }
    char * alias = data;
    free(data);
    /* POTENTIAL FLAW: `alias` points at the freed buffer */
    printLine(alias);
}
