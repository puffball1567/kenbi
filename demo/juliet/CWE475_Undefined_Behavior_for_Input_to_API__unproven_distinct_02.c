/* STATE A — `copy_bytes` declares its destination exclusive (`@unique`), and this function
   passes it two pointers it was handed itself. Nothing says its own callers pass different
   objects, so nothing shows the two are distinct: UNIQUE_UNPROVEN. */
/* CWE: 475 Undefined Behavior for Input to API (source and destination that may overlap) */
// @unique(dst)
// @borrows(dst)
// @borrows(src)
void copy_bytes(char *dst, const char *src, unsigned n);

// @kenbi
void CWE475_Undefined_Behavior_for_Input_to_API__unproven_distinct_02_bad(char *out, const char *in)
{
    /* POTENTIAL FLAW: `out` and `in` may point into the same object */
    copy_bytes(out, in, 8);
}
