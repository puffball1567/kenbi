// @spatial
/* STATE A — adopted, but the untrusted index reaches the buffer with NO bound check on the path.
   kenbi default-reds it: UNVALIDATED_INDEX. Progression: no-check -> wrong-variable -> right. */
/* CWE: 125 Out-of-bounds Read (no covering bound check) */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__unvalidated_index_07_bad(const unsigned char *buf, unsigned n, unsigned i)
{
    /* POTENTIAL FLAW: i reaches the subscript unchecked */
    return buf[i];
}
