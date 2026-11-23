/* STATE C — the function declares its own destination exclusive. Inside it, `out` then cannot
   be what `in` points into, and the requirement moves to this function's callers, where each
   call is checked the same way. GREEN. */
/* CWE: 475 Undefined Behavior for Input to API — fixed by declaring the requirement and
   letting each caller be checked against it. */
// @unique(dst)
// @borrows(dst)
// @borrows(src)
void copy_bytes(char *dst, const char *src, unsigned n);

// @kenbi
// @unique(out)
// @borrows(out)
// @borrows(in)
void CWE475_Undefined_Behavior_for_Input_to_API__unproven_distinct_02_fixed(char *out, const char *in)
{
    copy_bytes(out, in, 8);   /* FIXED: `out` is exclusive by this function's own declaration */
}
