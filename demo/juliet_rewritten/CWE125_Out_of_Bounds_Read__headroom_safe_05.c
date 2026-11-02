// @spatial
/* STATE C — the overflow-safe "remaining bytes" idiom `pos < end && end - pos >= 4`. The
   `pos < end` companion blocks the `end - pos` underflow; the arithmetic is on the trusted
   `end`, so pos never wraps. buf[pos] and buf[pos+3] are covered. GREEN. */
/* CWE: 125 Out-of-bounds Read — fixed with the two-variable remaining-bytes check. */
// @counted_by(buf: end)
int CWE125_Out_of_Bounds_Read__headroom_safe_05_fixed(const unsigned char *buf, unsigned end, unsigned pos)
{
    /* FIXED: `end - pos >= 4` under the `pos < end` companion */
    if (pos < end && end - pos >= 4)
        return buf[pos] + buf[pos + 3];
    return 0;
}
