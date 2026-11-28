/* STATE B — a half-fix: the increment is made unconditional, but the old conditional one is left
   in. On that path the count goes up by two, so it is STILL COUNT_RETAIN_MISMATCH. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

/* POTENTIAL FLAW: a non-empty buffer is counted twice for one share */
void buf_retain(struct Buf *b)
{
    b->refs++;
    if (b->len > 0) b->refs++;
}
