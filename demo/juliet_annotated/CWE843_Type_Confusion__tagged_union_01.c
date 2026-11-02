// @typecheck
/* STATE B — a half-fix: a discriminant IS checked, but to the WRONG value — reading `.i` needs
   `tag == 0`, but the guard proves `tag == 1`. The active variant does not match, so it is STILL
   TYPE_CONFUSION. Checking the wrong tag does not make the read safe. */
/* CWE: 843 Type Confusion (tagged union) */
typedef struct { int tag; union { int i; char *p; } u; } Node;

// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
int CWE843_Type_Confusion__tagged_union_01_bad(Node *n)
{
    /* POTENTIAL FLAW: `.i` needs tag == 0, but tag == 1 is proven here */
    if (n->tag == 1) { return n->u.i; }
    return 0;
}
