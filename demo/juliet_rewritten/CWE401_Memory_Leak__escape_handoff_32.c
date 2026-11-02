// @kenbi
/* STATE C — the hand-off is declared. `*slot` hands the buffer to an external owner (a queue /
   registry / system boundary); `@escapes` states that ownership legitimately leaves kenbi's view
   here, so releasing it is that owner's responsibility, not a leak. kenbi confirms it is safe.
   GREEN. This header is >6 lines so @kenbi binds FILE-LEVEL and covers the function.
   CWE: 401 Memory Leak — resolved: the escape is a declared, intentional hand-off.
   Padding line seven. */
#include <stdlib.h>

void CWE401_Memory_Leak__escape_handoff_32_fixed(char **slot, int n)
{
    /* @mem g::buf { free: free, owner: buf } */
    char *buf = (char *)malloc(n);
    if (buf == NULL) { return; }
    *slot = buf;  // @escapes
}
