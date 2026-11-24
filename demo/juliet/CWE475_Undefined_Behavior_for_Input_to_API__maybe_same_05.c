/* STATE A — `combine` declares its two buffers `@distinct`, and this function forwards two
   pointers it was handed. Nothing says its own callers pass different objects:
   DISTINCT_UNPROVEN. */
/* CWE: 475 Undefined Behavior for Input to API (two pointers that may be one object) */
// @distinct(dst, src)
// @borrows(dst)
// @borrows(src)
void combine(char *dst, const char *src, unsigned n);

// @kenbi
void CWE475_Undefined_Behavior_for_Input_to_API__maybe_same_05_bad(char *out, const char *in)
{
    /* POTENTIAL FLAW: `out` and `in` may be the same object */
    combine(out, in, 8);
}
