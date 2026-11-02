/* STATE A — un-annotated. The owned pointer escapes to `sink` twice with no @move contract, so
   kenbi cannot see the ownership transfer: a generic UNCONTRACTED_ESCAPE, not yet a double-move. */
/* CWE: 672 Operation on a Resource after Release (moved twice) */
#include <stdlib.h>
void sink(void *p);
void CWE672_Double_Move__move_twice_02_bad(int n) {
    char *p = malloc(n);
    if (!p) return;
    sink(p);
    sink(p);
}
