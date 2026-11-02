// @spatial
/* STATE C — the overflow-SAFE rewrite (GREEN). Keep the arithmetic on the TRUSTED limit so the
   untrusted `pos` never wraps: `len >= 5` blocks the `len - 5` underflow, and `pos <= len - 5`
   then bounds pos so the whole 4-byte read (up to index pos + 4) stays < len. kenbi confirms
   the read is in range. This is the check the state-B guard should have been. */
/*
 * CWE: 125 Out-of-bounds Read — fixed with an overflow-safe headroom check.
 */
unsigned get_u32(const unsigned char *p);

// @counted_by(buf: len)
int CWE125_Out_of_Bounds_Read__lookahead_01_fixed(const unsigned char *buf, unsigned len, unsigned pos)
{
    /* FIXED: overflow-safe — companion `len >= 5` blocks the underflow, arithmetic off `pos` */
    if (len >= 5 && pos <= len - 5)
        return (int)get_u32(buf + pos + 1);
    return 0;
}
