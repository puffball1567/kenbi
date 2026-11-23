#include <stdlib.h>
/* STATE B — a half-fix: `label_set` is declared `@borrows` so that the call passes. A borrowed
   pointer is given back when the call returns, and the body stores it in a field, so the
   declaration does not hold: BORROW_ESCAPES. */
/* CWE: 416 Use After Free (a borrowed pointer kept past the call) */
struct Label { const char *text; };

// @borrows(s)
void label_set(struct Label *l, const char *s)
{
    /* POTENTIAL FLAW: a borrowed pointer stored where it outlives the call */
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
