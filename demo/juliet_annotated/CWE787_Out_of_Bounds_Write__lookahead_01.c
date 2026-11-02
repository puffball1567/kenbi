// @spatial
/* STATE B — a bound guard is PRESENT but OVERFLOW-UNSAFE. `i + 4 <= len` computes `i + 4` on
   the untrusted `i`, which WRAPS for an unsigned value near the maximum (passing the check)
   while the 4-byte write at `dst + i` is out of range. kenbi judges the check itself:
   INAPPROPRIATE_BOUND. You cannot guard your way out with a wrap-prone check — still RED. */
/*
 * CWE: 787 Out-of-bounds Write
 * BadSink : put_u32(dst + i, v) guarded by the wrap-prone `i + 4 <= len`
 */
void put_u32(unsigned char *p, unsigned v);

// @counted_by(dst: len)
void CWE787_Out_of_Bounds_Write__lookahead_01_bad(unsigned char *dst, unsigned len, unsigned i, unsigned v)
{
    /* POTENTIAL FLAW: the guard's own arithmetic (`i + 4`) can wrap — not a sound bound */
    if (i + 4 <= len)
        put_u32(dst + i, v);
}
