// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN). CROSS-FILE (variant 22).
   Single owner across the file boundary: the caller allocates and HANDS the buffer
   to the sink (declared @frees in the prototype it sees); it does NOT also free.
   Ownership transfers once, across files, and the buffer is freed exactly once.
   The partner file (22b) defines the sink that honours @frees. */
/* CWE415_Double_Free__malloc_free_char_22a.c — fixed */

#include "std_testcase.h"

#include <wchar.h>

/* the sink (defined in 22b) takes ownership and frees it once */
// @frees(data)
void CWE415_Double_Free__malloc_free_char_22_badSink(char * data);

void CWE415_Double_Free__malloc_free_char_22_fixed()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    /* FIXED: do not free here — ownership is handed to the sink, which frees it */
    CWE415_Double_Free__malloc_free_char_22_badSink(data);
}
