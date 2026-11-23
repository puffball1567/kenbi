/* STATE A — `fill` declares its destination exclusive (`@unique`): for the length of the call
   nothing else reaches that object. It then keeps the pointer in a global, so something else
   does reach it once the call has returned: UNIQUE_ESCAPES. */
/* CWE: 475 Undefined Behavior for Input to API (an exclusive pointer kept past the call) */
static char *last_written;

// @kenbi
// @unique(dst)
void CWE475_Undefined_Behavior_for_Input_to_API__exclusive_kept_03_bad(char *dst, unsigned n)
{
    for (unsigned i = 0; i < n; i++) dst[i] = 0;
    /* POTENTIAL FLAW: the exclusive pointer is stored where it outlives the call */
    last_written = dst;
}
