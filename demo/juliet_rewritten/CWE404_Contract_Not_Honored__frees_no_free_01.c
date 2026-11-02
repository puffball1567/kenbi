/* STATE C — the @frees(o) contract is honoured: `o` is released on every path. GREEN. */
/* CWE: 404 Improper Resource Shutdown or Release — fixed by freeing as declared. */
#include <stdlib.h>
// @frees(o)
void CWE404_Contract_Not_Honored__frees_no_free_01_fixed(char *o) {
    free(o);
}
