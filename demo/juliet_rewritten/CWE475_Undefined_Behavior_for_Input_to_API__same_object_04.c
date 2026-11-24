#include <stdlib.h>
/* STATE C — the source is a block of its own, so the two arguments are different objects.
   GREEN. */
/* CWE: 475 Undefined Behavior for Input to API — fixed by passing two objects. */
// @distinct(dst, src)
// @borrows(dst)
// @borrows(src)
void combine(char *dst, const char *src, unsigned n);

void CWE475_Undefined_Behavior_for_Input_to_API__same_object_04_fixed(void)
{
    /* @mem app::row { alloc: malloc, free: free, owner: row } */
    char *row = malloc(16);
    if (!row) return;
    /* @mem app::tmp { alloc: malloc, free: free, owner: tmp } */
    char *tmp = malloc(16);
    if (!tmp) { free(row); return; }
    combine(row, tmp, 16);   /* FIXED: a separate block */
    free(tmp);
    free(row);
}
