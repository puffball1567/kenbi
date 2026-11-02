/* STATE B — a half-fix: one error path now routes through the funnel (`goto cleanup`), but the
   other still returns directly, owning `p`. STILL FINALLY_BYPASSED — every owning exit must route
   through cleanup. */
/* CWE: 459 Incomplete Cleanup */
#include <stdlib.h>
void CWE459_Incomplete_Cleanup__finally_bypassed_01_bad(int n, int err, int err2)
{
    /* @mem demo::a { free: free, owner: p } */
    char *p = malloc(n);   /* POTENTIAL FLAW: the err2 path below still bypasses the funnel */
    if (!p) return;
    if (err) goto cleanup;
    if (err2) return;
    // @goto_finally
cleanup:
    free(p);
}
