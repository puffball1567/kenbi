// @typecheck
/* STATE A — adopted for type checking (@typecheck) with each union member declared @variant of
   its tag value, but a member is read with NO discriminant check. kenbi default-reds it:
   TYPE_CONFUSION. (Progression: no-check -> wrong-tag -> right-tag.) */
/* CWE: 843 Type Confusion (tagged union) */
typedef struct { int tag; union { int i; char *p; } u; } Node;

// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
char *CWE843_Type_Confusion__tagged_union_01_bad(Node *n)
{
    /* POTENTIAL FLAW: read `.p` without checking tag == 1 */
    return n->u.p;
}
