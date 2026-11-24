/* STATE C — the function declares the same requirement of its own parameters. Inside it they
   are different objects, and each of its callers is checked in turn. GREEN. */
/* CWE: 475 Undefined Behavior for Input to API — fixed by declaring the requirement and
   letting each caller be checked against it. */
// @distinct(dst, src)
// @borrows(dst)
// @borrows(src)
void combine(char *dst, const char *src, unsigned n);

// @kenbi
// @distinct(out, in)
// @borrows(out)
// @borrows(in)
void CWE475_Undefined_Behavior_for_Input_to_API__maybe_same_05_fixed(char *out, const char *in)
{
    combine(out, in, 8);   /* FIXED: declared distinct by this function */
}
