#include <stdlib.h>
/* STATE A — `copy_bytes` declares its destination exclusive (`@unique`): its result is wrong
   when source and destination overlap. The call passes a block and a pointer into the same
   block: UNIQUE_ALIASED. */
/* CWE: 475 Undefined Behavior for Input to API (overlapping source and destination) */
// @unique(dst)
// @borrows(dst)
void copy_bytes(char *dst, const char *src, unsigned n);

void CWE475_Undefined_Behavior_for_Input_to_API__overlap_01_bad(void)
{
    /* @mem app::row { alloc: malloc, free: free, owner: row } */
    char *row = malloc(16);
    if (!row) return;
    /* POTENTIAL FLAW: both arguments point into `row` */
    copy_bytes(row, row + 4, 8);
    free(row);
}
