/* STATE A — un-annotated. `consume` frees its argument, but with no @frees contract kenbi cannot
   see the hand-off across the boundary: the later caller free is only a POSSIBLE double free (the
   callee MAY already have freed it), not yet a decided double-free.
   CWE: 415 Double Free (ownership handed to a callee that frees it, then freed again by the caller). */
#include <stdlib.h>
static void consume(char *p) { free(p); }

void CWE415_Double_Free__possible_handoff_54_bad(int n)
{
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    consume(p);        /* uncontracted callee frees p ... */
    free(p);           /* ... and the caller frees it again */
}
