/* STATE A — un-annotated. `release` frees its argument, but with no @frees contract kenbi cannot
   see the hand-off: the later use of `p` is only a POSSIBLE use-after-free (the callee MAY already
   have freed it), not yet a decided one.
   CWE: 416 Use After Free (a callee frees the buffer, then the caller uses it). */
#include <stdlib.h>
static void release(char *p) { free(p); }

void CWE416_Use_After_Free__possible_handoff_54_bad(int n)
{
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    release(p);        /* uncontracted callee frees p ... */
    p[0] = 'x';        /* ... and the caller uses it afterwards */
}
