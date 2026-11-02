/* STATE A — un-annotated. `consume` frees its argument, but with no @frees contract kenbi
   cannot see the handoff across the boundary: the owned pointer escaping to an uncontracted
   callee is a generic UNCONTRACTED_ESCAPE, not yet a double-free diagnosis. */
/* CWE: 415 Double Free (ownership handed to a @frees callee, then also freed by the caller) */
#include <stdlib.h>
static void consume(char *p) { free(p); }

void CWE415_Double_Free__frees_handoff_03_bad(int n)
{
    char *p = (char *)malloc(n);
    if (p == NULL) { return; }
    free(p);
    consume(p);
}
