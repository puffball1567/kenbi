// @refcheck
/* STATE B — a half-fix: the accessor is declared, but as returning a pointer into none of its
   arguments. The body returns one into `b`, so it is STILL REF_RETURN_UNDECLARED. */
/* CWE: 416 Use After Free (accessor result kept across a reallocation) */
struct Buf { char *data; unsigned len, cap; };

// @returns_into()
char *buf_data(struct Buf *b)
{
    /* POTENTIAL FLAW: the declaration says the result is not into `b` */
    return b->data;
}
