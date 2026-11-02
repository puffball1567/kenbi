// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN).
   The use-after-free is gone: the buffer is USED while still live, then freed
   exactly once, and never touched afterwards. The ownership obligation is
   discharged by the single free(). kenbi confirms the function is safe. */
/*
 * CWE: 416 Use After Free — fixed.
 */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

void CWE416_Use_After_Free__malloc_free_char_01_fixed()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    memset(data, 'A', 100-1);
    data[100-1] = '\0';
    /* use the buffer while it is still live */
    printLine(data);
    /* FIXED: free once, AFTER the last use; do not use data again */
    free(data);
}
