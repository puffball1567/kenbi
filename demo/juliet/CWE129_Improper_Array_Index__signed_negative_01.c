// @spatial
/* STATE A — adopted for spatial checking, but a SIGNED index reaches the buffer with NO bound
   at all. kenbi default-reds it — UNVALIDATED_INDEX (a wholly-unbounded value gets the single
   upper-bound complaint before the lower-bound one). */
/*
 * CWE: 129 Improper Validation of Array Index (negative index)
 * BadSink : buf[idx] — signed idx, no bound
 */
// @counted_by(buf: n)
int CWE129_Improper_Array_Index__signed_negative_01_bad(const char *buf, int n, int idx)
{
    /* POTENTIAL FLAW: no bound on the signed index */
    return buf[idx];
}
