// @spatial
/* STATE C — the guard leaves headroom: `count < cap` means count++ reaches at most cap, so
   `count <= cap` is preserved. kenbi verifies the @maintains claim. GREEN. */
/* CWE: 1284 Improper Validation of Specified Quantity — fixed with a strict `< cap` guard. */
struct Pool { int count; };

// @invariant(p->count <= cap)
void CWE1284_Invariant_Not_Maintained__capacity_01_fixed(struct Pool *p, int cap)
{
    if (p->count < cap) { p->count++; }    // @maintains(p->count <= cap)
}
