// @spatial
/* STATE C — the guard bounds the index actually used (`i < n`), so it is validated against the
   buffer's own count. GREEN. */
/* CWE: 125 Out-of-bounds Read — fixed by bounding the index that is used. */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__unvalidated_index_07_fixed(const unsigned char *buf, unsigned n, unsigned i)
{
    if (i < n) { return buf[i]; }
    return 0;
}
