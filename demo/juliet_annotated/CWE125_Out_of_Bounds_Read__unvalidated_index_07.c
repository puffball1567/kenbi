// @spatial
/* STATE B — a check IS present, but it bounds the WRONG variable: `j < n` says nothing about
   `i`, which still reaches the subscript unbounded. STILL UNVALIDATED_INDEX. */
/* CWE: 125 Out-of-bounds Read (no covering bound check) */
// @counted_by(buf: n)
int CWE125_Out_of_Bounds_Read__unvalidated_index_07_bad(const unsigned char *buf, unsigned n, unsigned i, unsigned j)
{
    /* POTENTIAL FLAW: the guard bounds j, but i is the index */
    if (j < n) { return buf[i]; }
    return 0;
}
