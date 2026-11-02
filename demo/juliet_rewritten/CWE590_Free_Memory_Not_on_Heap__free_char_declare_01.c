// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN).
   The non-heap free is gone: the buffer is allocated on the HEAP, declared as a
   resource owned by `data`, and freed exactly once. Only heap allocations may be
   freed, so kenbi now confirms the function is safe. */
/*
 * CWE: 590 Free Memory Not on Heap — fixed.
 */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

void CWE590_Free_Memory_Not_on_Heap__free_char_declare_01_fixed()
{
    char * data;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    memset(data, 'A', 100-1);
    data[100-1] = '\0';
    printLine(data);
    /* FIXED: free heap memory exactly once */
    free(data);
}
