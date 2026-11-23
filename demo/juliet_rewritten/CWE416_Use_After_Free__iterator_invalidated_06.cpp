// @refcheck
/* STATE C — `erase` returns the iterator to the element after the erased one; continuing from
   that is the form the container supports. GREEN. */
/* CWE: 416 Use After Free — fixed by continuing from the iterator `erase` returns. */
#include <vector>

void CWE416_Use_After_Free__iterator_invalidated_06_fixed(std::vector<int> &v)
{
    auto it = v.begin();
    while (it != v.end()) {
        if (*it == 0) it = v.erase(it);   /* FIXED: the iterator the erase hands back */
        else ++it;
    }
}
