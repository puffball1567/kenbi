// @typecheck
/* STATE C — the matching discriminant is proven before the read (`tag == 0` guards `.i`). kenbi
   confirms the active variant. GREEN. */
/* CWE: 843 Type Confusion — fixed by checking the correct discriminant. */
typedef struct { int tag; union { int i; char *p; } u; } Node;

// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
int CWE843_Type_Confusion__tagged_union_01_fixed(Node *n)
{
    if (n->tag == 0) { return n->u.i; }   /* FIXED: correct tag checked */
    return -1;
}
