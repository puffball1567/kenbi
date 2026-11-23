#include <stdlib.h>
/* STATE B — a half-fix: the source is given a name of its own. It is still a pointer into the
   same block, and kenbi follows where it came from, so it is STILL UNIQUE_ALIASED. */
/* CWE: 475 Undefined Behavior for Input to API (overlapping source and destination) */
// @unique(dst)
// @borrows(dst)
void copy_bytes(char *dst, const char *src, unsigned n);

void CWE475_Undefined_Behavior_for_Input_to_API__overlap_01_bad(void)
{
    /* @mem app::row { alloc: malloc, free: free, owner: row } */
    char *row = malloc(16);
    if (!row) return;
    char *tail = row + 4;
    /* POTENTIAL FLAW: `tail` is another name for part of `row` */
    copy_bytes(row, tail, 8);
    free(row);
}
