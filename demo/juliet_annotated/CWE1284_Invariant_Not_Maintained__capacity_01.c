// @spatial
/* STATE B — a half-fix with an OFF-BY-ONE guard: `count <= cap` still admits count == cap, and
   then `count++` makes it cap + 1, breaking `count <= cap`. STILL INVARIANT_NOT_MAINTAINED — the
   guard must leave headroom for the increment. */
/* CWE: 1284 Improper Validation of Specified Quantity (capacity invariant) */
struct Pool { int count; };

// @invariant(p->count <= cap)
void CWE1284_Invariant_Not_Maintained__capacity_01_bad(struct Pool *p, int cap)
{
    /* POTENTIAL FLAW: `<= cap` admits count == cap, so count++ reaches cap + 1 */
    if (p->count <= cap) { p->count++; }   // @maintains(p->count <= cap)
}
