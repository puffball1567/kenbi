// @spatial
/* STATE A — adopted with a declared field invariant, but a write to the PROTECTED field is
   UNANNOTATED. The write barrier default-reds any write to a `@invariant` field that does not
   declare its effect: UNGUARDED_INVARIANT_WRITE. Progression: unannotated -> guarded-but-
   undeclared -> @maintains-declared. */
/* CWE: 1284 Improper Validation of Specified Quantity (unguarded write to an invariant field) */
struct Pool { int count; };
// @invariant(p->count <= cap)
void CWE1284_Unguarded_Invariant_Write__protected_field_01_bad(struct Pool *p, int cap) {
    p->count++;   /* POTENTIAL FLAW: write to a protected field with no declared effect */
}
