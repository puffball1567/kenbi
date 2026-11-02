/* STATE A — `@goto_finally cleanup` declares the cleanup funnel, but the `if (err) return;` path
   exits still owning `p` WITHOUT routing through it. kenbi default-reds the bypassed cleanup:
   FINALLY_BYPASSED. Progression: bypass -> one-path-routed-one-not -> all routed. */
/* CWE: 459 Incomplete Cleanup */
#include <stdlib.h>
void CWE459_Incomplete_Cleanup__finally_bypassed_01_bad(int n, int err)
{
    /* @mem demo::a { free: free, owner: p } */
    char *p = malloc(n);   /* POTENTIAL FLAW: an exit below bypasses the funnel while owning p */
    if (!p) return;
    if (err) return;
    // @goto_finally
cleanup:
    free(p);
}
