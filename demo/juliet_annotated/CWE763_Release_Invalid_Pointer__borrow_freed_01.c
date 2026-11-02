/* STATE B — a half-fix: the borrowed pointer is freed only on a branch, but that path still
   releases memory the borrower does not own. STILL BORROW_FREED. */
/* CWE: 763 Release of Invalid Pointer or Reference */
#include <stdlib.h>
// @borrows(p)
void CWE763_Release_Invalid_Pointer__borrow_freed_01_bad(char *p, int c)
{
    /* POTENTIAL FLAW: frees the borrow on the c-path */
    if (c) { free(p); }
}
