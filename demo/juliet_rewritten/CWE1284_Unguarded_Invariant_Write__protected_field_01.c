// @spatial
/* STATE C — the write DECLARES its effect with `@maintains`, discharging the write barrier so the
   invariant stays trustworthy. GREEN. */
/* CWE: 1284 Improper Validation of Specified Quantity — fixed by declaring @maintains. */
struct Pool { int count; };
// @invariant(p->count <= cap)
void CWE1284_Unguarded_Invariant_Write__protected_field_01_fixed(struct Pool *p, int cap) {
    if (p->count >= cap) return;
    p->count++;   // @maintains(p->count <= cap)
}
