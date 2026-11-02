/* STATE A — `rel` is declared @frees(o) (the caller trusts it to release `o`), but the body never
   frees it — a leak the caller cannot see. kenbi default-reds the broken contract:
   CONTRACT_NOT_HONORED. (The bug is contract-relative — it exists once @frees is declared — so
   state A carries the annotation; the progression is never-frees -> frees-one-path -> frees.) */
/* CWE: 404 Improper Resource Shutdown or Release (declared @frees but does not free) */
#include <stdlib.h>
// @frees(o)
void CWE404_Contract_Not_Honored__frees_no_free_01_bad(char *o) {
    (void)o;   /* POTENTIAL FLAW: declared @frees(o) but never frees o */
}
