/* STATE B — a half-fix: the destination is copied into a local pointer first. A new name is
   not a new object — the local points wherever `out` does — so it is STILL UNIQUE_UNPROVEN. */
/* CWE: 475 Undefined Behavior for Input to API (source and destination that may overlap) */
// @unique(dst)
// @borrows(dst)
// @borrows(src)
void copy_bytes(char *dst, const char *src, unsigned n);

// @kenbi
void CWE475_Undefined_Behavior_for_Input_to_API__unproven_distinct_02_bad(char *out, const char *in)
{
    char *dst = out;
    /* POTENTIAL FLAW: `dst` is `out` under another name */
    copy_bytes(dst, in, 8);
}
