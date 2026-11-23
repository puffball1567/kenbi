// @refcheck
/* STATE A — an accessor returns a pointer into the buffer it is given without saying so. Its
   callers cannot be checked against a later reallocation unless they are told:
   REF_RETURN_UNDECLARED. */
/* CWE: 416 Use After Free (accessor result kept across a reallocation) */
struct Buf { char *data; unsigned len, cap; };

char *buf_data(struct Buf *b)
{
    /* POTENTIAL FLAW: the result points into `b`, and nothing declares it */
    return b->data;
}
