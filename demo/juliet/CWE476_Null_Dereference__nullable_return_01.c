/* STATE A — `lookup` is declared @nullable (it may return NULL), yet the result is dereferenced
   with NO null check. kenbi default-reds the possibly-null deref: NULL_DEREF. */
/* CWE: 476 NULL Pointer Dereference */
extern char *lookup(int);

char CWE476_Null_Dereference__nullable_return_01_bad(int n)
{
    char *p = lookup(n);   // @nullable
    /* POTENTIAL FLAW: deref without excluding NULL */
    return *p;
}
