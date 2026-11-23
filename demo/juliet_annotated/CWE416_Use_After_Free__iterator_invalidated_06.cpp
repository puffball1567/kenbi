// @refcheck
/* STATE B — a half-fix: the next position is saved before the erase and used afterwards. But
   erasing from a vector invalidates every iterator at or after the erased element, the saved
   one included, so it is STILL REF_INVALIDATED. */
/* CWE: 416 Use After Free (iterator used after the container changed) */
#include <vector>

void CWE416_Use_After_Free__iterator_invalidated_06_bad(std::vector<int> &v)
{
    auto it = v.begin();
    while (it != v.end()) {
        if (*it == 0) {
            auto next = it + 1;
            v.erase(it);
            /* POTENTIAL FLAW: `next` was taken before the erase and is invalid too */
            it = next;
        } else {
            ++it;
        }
    }
}
