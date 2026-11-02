// @spatial
/* STATE B — a runtime guard is present, but the write still does not DECLARE its effect on the
   invariant. The write barrier requires the `@maintains` declaration (which makes the invariant
   trustworthy), not merely a guard, so it is STILL UNGUARDED_INVARIANT_WRITE. */
/* CWE: 1284 Improper Validation of Specified Quantity (unguarded write to an invariant field) */
struct Pool { int count; };
// @invariant(p->count <= cap)
void CWE1284_Unguarded_Invariant_Write__protected_field_01_bad(struct Pool *p, int cap) {
    if (p->count >= cap) return;
    p->count++;   /* POTENTIAL FLAW: guarded, but the write declares no @maintains effect */
}
