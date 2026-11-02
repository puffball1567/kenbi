/* STATE A — un-annotated. The buffer is stored through an out-slot (`*slot = buf`) and freed
   nowhere in view. With no ownership declared, kenbi cannot follow where the buffer goes: the
   store is a generic UNCONTRACTED boundary, not yet a decided leak.
   CWE: 401 Memory Leak (ownership escapes through a slot kenbi cannot follow). */
#include <stdlib.h>

void CWE401_Memory_Leak__escape_handoff_32_bad(char **slot, int n)
{
    char *buf = (char *)malloc(n);
    if (buf == NULL) { return; }
    *slot = buf;          /* ownership escapes through the slot */
}
