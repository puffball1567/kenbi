// @spatial
/* STATE C — the companion `n >= 4` blocks the `n - 4` underflow, so `i <= n - 4` soundly bounds
   i..i+3 within an n-element buffer. GREEN. */
/*
 * CWE: 125 Out-of-bounds Read — fixed with the `n >= 4` companion guard.
 */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__limit_underflow_03_fixed(const unsigned char *buf, unsigned n, unsigned i)
{
    /* FIXED: companion `n >= 4` first, then `i <= n - 4` */
    if (n >= 4 && i <= n - 4)
        return buf[i] + buf[i + 3];
    return 0;
}
