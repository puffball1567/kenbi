#include <stdlib.h>
/* STATE C — the bytes are copied out to a separate local first, so the exclusive destination
   and the source are different objects. GREEN. */
/* CWE: 475 Undefined Behavior for Input to API — fixed by copying through a separate object. */
// @unique(dst)
// @borrows(dst)
void copy_bytes(char *dst, const char *src, unsigned n);

void CWE475_Undefined_Behavior_for_Input_to_API__overlap_01_fixed(void)
{
    /* @mem app::row { alloc: malloc, free: free, owner: row } */
    char *row = malloc(16);
    if (!row) return;
    char tmp[8];
    copy_bytes(tmp, row + 4, 8);   /* FIXED: out to a separate object ... */
    copy_bytes(row, tmp, 8);       /* ... and back from it */
    free(row);
}
