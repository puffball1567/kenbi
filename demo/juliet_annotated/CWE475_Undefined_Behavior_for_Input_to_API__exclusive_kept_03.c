/* STATE B — a half-fix: a pointer to the end of the block is kept instead of the pointer
   itself. It points into the same object, so it is STILL UNIQUE_ESCAPES. */
/* CWE: 475 Undefined Behavior for Input to API (an exclusive pointer kept past the call) */
static char *last_written;

// @kenbi
// @unique(dst)
void CWE475_Undefined_Behavior_for_Input_to_API__exclusive_kept_03_bad(char *dst, unsigned n)
{
    for (unsigned i = 0; i < n; i++) dst[i] = 0;
    char *end = dst + n;
    /* POTENTIAL FLAW: `end` is derived from the exclusive pointer */
    last_written = end;
}
