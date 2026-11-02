// @spatial
/* STATE C — the overflow-SAFE rewrite (GREEN). Keep the arithmetic on the TRUSTED limit:
   `len >= 4` blocks the `len - 4` underflow, and `i <= len - 4` then bounds i so the whole
   4-byte write (up to index i + 3) stays < len. kenbi confirms the write is in range. */
/*
 * CWE: 787 Out-of-bounds Write — fixed with an overflow-safe headroom check.
 */
void put_u32(unsigned char *p, unsigned v);

// @counted_by(dst: len)
void CWE787_Out_of_Bounds_Write__lookahead_01_fixed(unsigned char *dst, unsigned len, unsigned i, unsigned v)
{
    /* FIXED: overflow-safe — companion `len >= 4` blocks the underflow, arithmetic off `i` */
    if (len >= 4 && i <= len - 4)
        put_u32(dst + i, v);
}
