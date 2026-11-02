/* STATE A — un-annotated. A raw `new` with no declared resource, handed to `process`, whose
   ownership contract and throw behaviour are both undeclared: a generic UNKNOWN_RESOURCE /
   UNCONTRACTED_ESCAPE, not yet a diagnosis of the exception path. */
/* CWE: 401 Memory Leak (on the exception path) */
#include <new>
void process(int *p);
int CWE401_Memory_Leak__exception_path_01_bad(int n) {
    int *p = new (std::nothrow) int(n);
    if (!p) return -1;
    process(p);
    delete p;
    return 0;
}
