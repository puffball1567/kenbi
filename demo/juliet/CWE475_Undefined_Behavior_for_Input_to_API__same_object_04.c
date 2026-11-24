#include <stdlib.h>
/* STATE A — `combine` declares its two buffers `@distinct`: it reads one while it writes the
   other. The call passes the same block for both: DISTINCT_ALIASED. */
/* CWE: 475 Undefined Behavior for Input to API (one object where two are required) */
// @distinct(dst, src)
// @borrows(dst)
// @borrows(src)
void combine(char *dst, const char *src, unsigned n);

void CWE475_Undefined_Behavior_for_Input_to_API__same_object_04_bad(void)
{
    /* @mem app::row { alloc: malloc, free: free, owner: row } */
    char *row = malloc(16);
    if (!row) return;
    /* POTENTIAL FLAW: `row` is both the destination and the source */
    combine(row, row, 16);
    free(row);
}
