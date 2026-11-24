#include <stdlib.h>
/* STATE B — a half-fix: the source is passed through a second variable. It holds the same
   pointer, and kenbi follows what each variable is bound to, so it is STILL
   DISTINCT_ALIASED. */
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
    char *from = row;
    /* POTENTIAL FLAW: `from` is `row` under another name */
    combine(row, from, 16);
    free(row);
}
