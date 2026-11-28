/* STATE B — a half-fix: one of the two callees is declared. The other still says nothing, so it
   is STILL COUNT_UNPROVEN. */
/* CWE: 911 Improper Update of Reference Count */
// @refcounted Buf { count: refs, retain: buf_retain, release: buf_release }
struct Buf { int refs; int len; };

// @owns
struct Buf *buf_new(int len);
// @borrows(b)
void buf_retain(struct Buf *b);
// @frees(b)
void buf_release(struct Buf *b);

// @borrows(b)
void log_buf(struct Buf *b);
void audit_buf(struct Buf *b);

void CWE911_Improper_Update_of_Reference_Count__undeclared_callee_04_bad(struct Buf *b)
{
    log_buf(b);
    /* POTENTIAL FLAW: `audit_buf` is still undeclared */
    audit_buf(b);
}
