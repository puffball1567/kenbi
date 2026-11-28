/* STATE A — the counter is incremented and decremented by hand. The decrement never tests for
   zero, so a last share given back this way frees nothing — and nothing checks that the two
   are paired: COUNT_DIRECT_WRITE. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

void work(void);

void CWE911_Improper_Update_of_Reference_Count__counter_written_directly_01_bad(struct Buf *b)
{
    /* POTENTIAL FLAW: the count changes behind the back of buf_retain / buf_release */
    b->refs++;
    work();
    b->refs--;
}
