// @spatial
/* STATE B — an UPPER bound is now present (`idx < n`), but `idx` is SIGNED and nothing shows it
   is >= 0, so it could be negative and index below the buffer. kenbi reports the specific
   gap: INDEX_MAYBE_NEGATIVE ("bounded above but not below"). Bounding one end is not enough. */
/*
 * CWE: 129 Improper Validation of Array Index (negative index)
 * BadSink : buf[idx] guarded only by the upper bound `idx < n`
 */
// @counted_by(buf: n)
int CWE129_Improper_Array_Index__signed_negative_01_bad(const char *buf, int n, int idx)
{
    /* POTENTIAL FLAW: upper bound only — a negative idx still reads below buf */
    if (idx < n)
        return buf[idx];
    return 0;
}
