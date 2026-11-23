/* STATE C — what the function needs to remember is how much it wrote, not where: it keeps the
   count, and no pointer outlives the call. GREEN. */
/* CWE: 475 Undefined Behavior for Input to API — fixed by keeping a value instead of the
   pointer. */
static unsigned last_count;

// @kenbi
// @unique(dst)
void CWE475_Undefined_Behavior_for_Input_to_API__exclusive_kept_03_fixed(char *dst, unsigned n)
{
    for (unsigned i = 0; i < n; i++) dst[i] = 0;
    last_count = n;   /* FIXED: a count, not a pointer */
}
