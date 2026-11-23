// @refcheck
/* STATE A — an element is erased through the iterator the loop then steps. `erase` invalidates
   that iterator, so `++it` uses one that no longer refers into the vector: REF_INVALIDATED. */
/* CWE: 416 Use After Free (iterator used after the container changed) */
#include <vector>

void CWE416_Use_After_Free__iterator_invalidated_06_bad(std::vector<int> &v)
{
    /* POTENTIAL FLAW: `++it` runs on an iterator `erase` has invalidated */
    for (auto it = v.begin(); it != v.end(); ++it) {
        if (*it == 0) v.erase(it);
    }
}
