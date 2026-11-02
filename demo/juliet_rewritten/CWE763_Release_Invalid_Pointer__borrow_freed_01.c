/* STATE C — the borrowed pointer is USED (written through) but never freed; the owner keeps the
   deallocation responsibility. GREEN. */
/* CWE: 763 Release of Invalid Pointer or Reference — fixed by not freeing the borrow. */
#include <stdlib.h>
// @borrows(p)
void CWE763_Release_Invalid_Pointer__borrow_freed_01_fixed(char *p)
{
    p[0] = 0;   /* FIXED: use the borrow, leave freeing to the owner */
}
