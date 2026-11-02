// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN).
   Cross-function ownership made explicit: bad()'s leak is fixed by handing the
   buffer to a sink that is declared to free it (@frees). Ownership transfers
   across the call boundary and the buffer is freed exactly once. kenbi confirms
   it is safe. */
/*
 * CWE: 401 Memory Leak — fixed (cross-function, single owner).
 */

#include "std_testcase.h"

#include <wchar.h>

// @borrows(line)
void printLine(const char * line);

/* the sink takes ownership and releases it */
// @frees(data)
static void sink(char * data)
{
    free(data);
}

void CWE401_Memory_Leak__char_malloc_41_fixed()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    strcpy(data, "A String");
    printLine(data);
    /* FIXED: hand ownership to sink(), which frees it exactly once */
    sink(data);
}
