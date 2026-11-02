/* STATE A — `consume` @borrows its pointer (the caller still owns it), but it FREES it. Freeing a
   borrowed pointer is the owner's job, not the borrower's. kenbi default-reds it: BORROW_FREED.
   Progression: free -> conditional free -> use without freeing. */
/* CWE: 763 Release of Invalid Pointer or Reference */
#include <stdlib.h>
// @borrows(p)
void CWE763_Release_Invalid_Pointer__borrow_freed_01_bad(char *p)
{
    /* POTENTIAL FLAW: freeing a borrowed pointer */
    free(p);
}
