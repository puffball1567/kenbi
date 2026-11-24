/* STATE B — a half-fix: the pointers are copied into locals first. Each local points wherever
   the parameter did, so it is STILL DISTINCT_UNPROVEN. */
/* CWE: 475 Undefined Behavior for Input to API (two pointers that may be one object) */
// @distinct(dst, src)
// @borrows(dst)
// @borrows(src)
void combine(char *dst, const char *src, unsigned n);

// @kenbi
void CWE475_Undefined_Behavior_for_Input_to_API__maybe_same_05_bad(char *out, const char *in)
{
    char *dst = out;
    const char *src = in;
    /* POTENTIAL FLAW: new names, the same two objects */
    combine(dst, src, 8);
}
