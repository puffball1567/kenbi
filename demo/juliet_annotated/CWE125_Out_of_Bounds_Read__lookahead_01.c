// @spatial
/* STATE B — a bound guard is now PRESENT, but it is OVERFLOW-UNSAFE (the everyday-looking
   parser check). `pos + 5 <= len` computes `pos + 5` on the untrusted `pos`, which WRAPS for
   an unsigned value near the maximum (pos = 0xFFFFFFFE => pos+5 == 3 <= len passes) while the
   4-byte read at `buf + pos + 1` is ~4 GB out of range. kenbi judges the check ITSELF, not
   its mere presence: INAPPROPRIATE_BOUND. You cannot guard your way out with a wrap-prone
   check — it must STILL be RED. */
/*
 * CWE: 125 Out-of-bounds Read
 * BadSink : get_u32(buf + pos + 1) guarded by the wrap-prone `pos + 5 <= len`
 */
unsigned get_u32(const unsigned char *p);

// @counted_by(buf: len)
int CWE125_Out_of_Bounds_Read__lookahead_01_bad(const unsigned char *buf, unsigned len, unsigned pos)
{
    /* POTENTIAL FLAW: the guard's own arithmetic (`pos + 5`) can wrap — not a sound bound */
    if (pos + 5 <= len)
        return (int)get_u32(buf + pos + 1);
    return 0;
}
