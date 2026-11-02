// @spatial
/* STATE A — adopted with a declared field invariant `p->count <= cap`, but the increment is
   UNGUARDED: nothing bounds count below cap first, so `count++` can push it past cap. kenbi
   default-reds the broken claim: INVARIANT_NOT_MAINTAINED. Progression: no guard -> off-by-one
   guard -> correct guard. */
/* CWE: 1284 Improper Validation of Specified Quantity (capacity invariant) */
struct Pool { int count; };

// @invariant(p->count <= cap)
void CWE1284_Invariant_Not_Maintained__capacity_01_bad(struct Pool *p, int cap)
{
    /* POTENTIAL FLAW: unguarded increment can exceed cap */
    p->count++;                        // @maintains(p->count <= cap)
}
