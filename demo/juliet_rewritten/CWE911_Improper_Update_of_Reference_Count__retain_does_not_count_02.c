/* STATE C — one call, one increment, on every path. GREEN. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

void buf_retain(struct Buf *b)
{
    b->refs++;        /* FIXED: exactly one share per call */
}
