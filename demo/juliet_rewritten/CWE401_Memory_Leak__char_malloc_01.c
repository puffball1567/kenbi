// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN).
   The leak is gone: the heap buffer is owned by `data` and freed exactly once
   before the function returns, discharging the ownership obligation. kenbi
   confirms the function is safe. */
/*
 * CWE: 401 Memory Leak — fixed.
 */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

void CWE401_Memory_Leak__char_malloc_01_fixed()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    strcpy(data, "A String");
    printLine(data);
    /* FIXED: deallocate before returning */
    free(data);
}
