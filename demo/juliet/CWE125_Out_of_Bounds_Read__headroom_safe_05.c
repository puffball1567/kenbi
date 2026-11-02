// @spatial
/* STATE A — adopted, a look-ahead read buf[pos]/buf[pos+3] with NO bound. UNVALIDATED_INDEX. */
/* CWE: 125 Out-of-bounds Read (two-variable headroom idiom in state C) */
// @counted_by(buf: end)
int CWE125_Out_of_Bounds_Read__headroom_safe_05_bad(const unsigned char *buf, unsigned end, unsigned pos)
{
    /* POTENTIAL FLAW: no bound on pos */
    return buf[pos] + buf[pos + 3];
}
