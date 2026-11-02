// @spatial
/* STATE B — a check IS present, but it bounds the WRONG variable: `cap <= 64` says nothing about
   `len`, which still reaches memcpy unbounded. STILL UNVALIDATED_SIZE. */
/* CWE: 120 Buffer Copy without Checking Size of Input */
#include <string.h>
extern char dst[64];

void CWE120_Buffer_Overflow__unvalidated_size_01_bad(const char *src, unsigned len, unsigned cap)
{
    /* POTENTIAL FLAW: the guard bounds cap, but len is the length */
    if (cap <= 64) { memcpy(dst, src, len); }
}
