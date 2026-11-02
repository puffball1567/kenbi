// @spatial
/* STATE B — the wrap-prone guard `pos + 4 <= end` (arithmetic on the untrusted pos) can wrap.
   INAPPROPRIATE_BOUND. */
/* CWE: 125 Out-of-bounds Read (two-variable headroom idiom in state C) */
// @counted_by(buf: end)
int CWE125_Out_of_Bounds_Read__headroom_safe_05_bad(const unsigned char *buf, unsigned end, unsigned pos)
{
    /* POTENTIAL FLAW: `pos + 4` wraps for a large unsigned pos */
    if (pos + 4 <= end)
        return buf[pos] + buf[pos + 3];
    return 0;
}
