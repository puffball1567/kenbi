// @spatial
/* STATE C — both ends are bounded (`idx >= 0 && idx < n`), so the signed index is provably in
   range. kenbi confirms the read is safe. GREEN. */
/*
 * CWE: 129 Improper Validation of Array Index — fixed with a two-sided bound.
 */
// @counted_by(buf: n)
int CWE129_Improper_Array_Index__signed_negative_01_fixed(const char *buf, int n, int idx)
{
    /* FIXED: lower AND upper bound */
    if (idx >= 0 && idx < n)
        return buf[idx];
    return 0;
}
