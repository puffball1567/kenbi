// @spatial
/* STATE C — the length actually passed to memcpy is bounded to the destination size
   (`len <= 64`), so the copy cannot overflow the 64-byte buffer. GREEN. */
/* CWE: 120 Buffer Copy without Checking Size of Input — fixed by bounding the copied length. */
#include <string.h>
extern char dst[64];

void CWE120_Buffer_Overflow__unvalidated_size_01_fixed(const char *src, unsigned len)
{
    if (len <= 64) { memcpy(dst, src, len); }
}
