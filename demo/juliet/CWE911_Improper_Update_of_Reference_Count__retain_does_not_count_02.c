/* STATE A — the function declared as the retain function increments the counter only when the
   buffer is not empty. A caller that retains an empty buffer holds a share that was never
   counted: COUNT_RETAIN_MISMATCH. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

/* POTENTIAL FLAW: on the path where `b->len` is 0 the count does not change */
void buf_retain(struct Buf *b)
{
    if (b->len > 0) b->refs++;
}
