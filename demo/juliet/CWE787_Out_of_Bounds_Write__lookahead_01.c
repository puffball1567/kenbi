// @spatial
/* STATE A — adopted for spatial checking, but the fixed-width WRITE has NO bound guard. A
   binary serialiser writes a 4-byte value at `dst + i` (touching index i+3) with nothing
   constraining the untrusted `i`. kenbi default-reds it — UNVALIDATED_INDEX. (Spatial is an
   opt-in axis, so state A carries the @spatial adoption; the progression is no-check ->
   wrong-check -> right-check.) */
/*
 * CWE: 787 Out-of-bounds Write
 * BadSink : put_u32(dst + i, v) — a 4-byte write at index i+3, no bound on i
 */
void put_u32(unsigned char *p, unsigned v);

// @counted_by(dst: len)
void CWE787_Out_of_Bounds_Write__lookahead_01_bad(unsigned char *dst, unsigned len, unsigned i, unsigned v)
{
    /* POTENTIAL FLAW: no bound check on `i` before a 4-byte write */
    put_u32(dst + i, v);
}
