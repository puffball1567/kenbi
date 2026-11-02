/* STATE B — a null check IS present, but the deref happens BEFORE it, so the possibly-null
   pointer is still dereferenced on the failing path. STILL NULL_DEREF — the guard is in the
   wrong place. */
/* CWE: 476 NULL Pointer Dereference */
extern char *lookup(int);

char CWE476_Null_Dereference__nullable_return_01_bad(int n)
{
    char *p = lookup(n);   // @nullable
    /* POTENTIAL FLAW: deref precedes the guard below */
    char c = *p;
    if (p) { return c; }
    return 0;
}
