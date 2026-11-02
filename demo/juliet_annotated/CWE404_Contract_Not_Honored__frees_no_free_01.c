/* STATE B — a half-fix: `o` is freed on only ONE branch, so the @frees(o) contract is broken on
   the other path (the caller trusts it was released on every path). STILL CONTRACT_NOT_HONORED. */
/* CWE: 404 Improper Resource Shutdown or Release (declared @frees but does not free) */
#include <stdlib.h>
// @frees(o)
void CWE404_Contract_Not_Honored__frees_no_free_01_bad(char *o, int c) {
    if (c) { free(o); }   /* POTENTIAL FLAW: the else path does not free o */
}
