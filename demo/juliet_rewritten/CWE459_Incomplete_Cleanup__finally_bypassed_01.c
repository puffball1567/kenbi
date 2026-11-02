/* STATE C — every owning error path routes through the cleanup funnel (`goto cleanup`), so `p` is
   always freed exactly once. GREEN. */
/* CWE: 459 Incomplete Cleanup — fixed by routing all exits through the funnel. */
#include <stdlib.h>
void CWE459_Incomplete_Cleanup__finally_bypassed_01_fixed(int n, int err, int err2)
{
    /* @mem demo::a { free: free, owner: p } */
    char *p = malloc(n);
    if (!p) return;
    if (err) goto cleanup;
    if (err2) goto cleanup;
    // @goto_finally
cleanup:
    free(p);
}
