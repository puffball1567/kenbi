/* STATE C — NULL is excluded on the path before the deref (`if (!p) return`), so the deref is
   provably of a non-null pointer. GREEN. */
/* CWE: 476 NULL Pointer Dereference — fixed by a null check before the deref. */
extern char *lookup(int);

char CWE476_Null_Dereference__nullable_return_01_fixed(int n)
{
    char *p = lookup(n);   // @nullable
    if (!p) { return 0; }  /* FIXED: exclude NULL first */
    return *p;
}
