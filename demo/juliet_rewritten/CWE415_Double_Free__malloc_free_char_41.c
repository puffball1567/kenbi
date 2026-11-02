// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN).
   Cross-function ownership made explicit and consistent: the buffer is allocated
   in the source, then HANDED to a sink that is declared to free it (@frees). The
   source does NOT also free it, so ownership transfers cleanly and the buffer is
   freed exactly once, across the call boundary. kenbi confirms it is safe. */
/*
 * CWE: 415 Double Free — fixed (cross-function, single owner).
 */

#include "std_testcase.h"

#include <wchar.h>

/* the sink takes ownership and releases it exactly once */
// @frees(data)
static void sink(char * data)
{
    free(data);
}

void CWE415_Double_Free__malloc_free_char_41_fixed()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    /* FIXED: do not free here — ownership is handed to sink(), which frees it */
    sink(data);
}
