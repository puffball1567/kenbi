#include <stdlib.h>
/* STATE A — `label_set` keeps the pointer it is given in a field, and its caller frees the
   string afterwards. With no contract on `label_set`, kenbi cannot tell what it does with the
   owned pointer: UNCONTRACTED_ESCAPE. */
/* CWE: 416 Use After Free (a borrowed pointer kept past the call) */
struct Label { const char *text; };

void label_set(struct Label *l, const char *s)
{
    /* POTENTIAL FLAW: `s` is kept; the caller still owns and frees it */
    l->text = s;
}

void CWE416_Use_After_Free__borrow_stored_10_bad(struct Label *l)
{
    /* @mem app::name { alloc: malloc, free: free, owner: name } */
    char *name = malloc(8);
    if (!name) return;
    name[0] = 0;
    label_set(l, name);
    free(name);
}
