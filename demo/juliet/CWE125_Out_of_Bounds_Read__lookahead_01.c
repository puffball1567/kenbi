// @spatial
/* STATE A — adopted for spatial checking (@spatial + @counted_by), but the look-ahead read
   has NO bound guard. This is the spatial analogue of the Juliet "bad sink": a binary parser
   reads a fixed-width 4-byte value at `buf + pos + 1` (reaching index pos + 4) with nothing
   constraining the untrusted `pos`. kenbi default-reds it — UNVALIDATED_INDEX ("no bound check
   is present"). NOTE: spatial is an OPT-IN axis, so unlike the temporal cases state A must
   still carry the @spatial adoption; the progression here is no-check -> wrong-check -> right
   -check rather than unannotated -> annotated -> fixed. */
/*
 * CWE: 125 Out-of-bounds Read
 * BadSink : get_u32(buf + pos + 1) — a 4-byte read at index pos+4, no bound on pos
 * GoodSink: prove pos + 4 < len with an overflow-safe check (state C)
 * Pilot: quickjs JS_ReadFunctionBytecode.
 */
unsigned get_u32(const unsigned char *p);

// @counted_by(buf: len)
int CWE125_Out_of_Bounds_Read__lookahead_01_bad(const unsigned char *buf, unsigned len, unsigned pos)
{
    /* POTENTIAL FLAW: no bound check on `pos` before a 4-byte look-ahead read */
    return (int)get_u32(buf + pos + 1);
}
