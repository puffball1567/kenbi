// @spatial
/* STATE A — adopted, but an untrusted length flows into memcpy with NO bound check (the classic
   overflow; kenbi follows the scalar through the local copy). kenbi default-reds it:
   UNVALIDATED_SIZE. Progression: no-check -> wrong-variable -> right. */
/* CWE: 120 Buffer Copy without Checking Size of Input */
#include <string.h>
extern char dst[64];

void CWE120_Buffer_Overflow__unvalidated_size_01_bad(const char *src, unsigned len)
{
    unsigned n = len;               /* taint follows the copy */
    /* POTENTIAL FLAW: unbounded length into memcpy */
    memcpy(dst, src, n);
}
