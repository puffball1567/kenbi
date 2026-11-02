// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN).
   The double free is gone: the heap buffer is declared as a resource owned by
   `data` and freed EXACTLY ONCE. kenbi now confirms the function is safe.
   Annotations are identical to STATE B — only the code changed (one free, not
   two), which is the whole point: the fix is in the code, not the annotation. */
/*
 * CWE: 415 Double Free — fixed.
 * Allocate data with malloc(); free it once.
 */

#include "std_testcase.h"

#include <wchar.h>

void CWE415_Double_Free__malloc_free_char_01_fixed()
{
    char * data;
    data = NULL;
    /* @mem g::buf { free: free, owner: data } */
    data = (char *)malloc(100*sizeof(char));
    if (data == NULL) {exit(-1);}
    /* use the buffer */
    memset(data, 'A', 100-1);
    data[100-1] = '\0';
    /* FIXED: free exactly once — the ownership obligation is discharged here */
    free(data);
}
