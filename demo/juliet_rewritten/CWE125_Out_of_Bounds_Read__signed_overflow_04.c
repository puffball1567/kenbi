// @spatial
/* STATE C — the overflow-safe rewrite keeps the arithmetic on the trusted limit: `i <= n - 4`.
   For a SIGNED limit this fails CLOSED (n - 4 goes negative when n < 4, so `i <= n - 4` is
   false and the branch is skipped) — no companion needed. With `i >= 0` the read is in range.
   GREEN. */
/* CWE: 125 Out-of-bounds Read — fixed, arithmetic off the untrusted index. */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__signed_overflow_04_fixed(const char *buf, int n, int i)
{
    /* FIXED: `i <= n - 4` (signed, fail-closed) instead of `i + 4 <= n` */
    if (i >= 0 && i <= n - 4)
        return buf[i];
    return 0;
}
