// @spatial
/* STATE C — the strict bound `i < n` keeps i in 0..n-1. GREEN. */
/*
 * CWE: 125 Out-of-bounds Read — fixed with a strict `i < n` bound.
 */
// @counted_by(buf: n)
unsigned char CWE125_Out_of_Bounds_Read__off_by_one_02_fixed(const unsigned char *buf, unsigned n, unsigned i)
{
    /* FIXED: strict bound */
    if (i < n)
        return buf[i];
    return 0;
}
