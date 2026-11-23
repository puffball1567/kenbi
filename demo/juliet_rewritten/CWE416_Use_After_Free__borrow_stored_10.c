#include <stdlib.h>
#include <string.h>
/* STATE C — `label_set` only reads the string (it copies the characters into storage the label
   already has), so `@borrows` is true of it and the caller's free is safe. GREEN. */
/* CWE: 416 Use After Free — fixed by copying the contents instead of keeping the pointer. */
struct Label { char text[16]; };

// @borrows(s)
void label_set(struct Label *l, const char *s)
{
    strncpy(l->text, s, sizeof l->text - 1);   /* FIXED: the contents are copied */
    l->text[sizeof l->text - 1] = 0;
}

void CWE416_Use_After_Free__borrow_stored_10_fixed(struct Label *l)
{
    /* @mem app::name { alloc: malloc, free: free, owner: name } */
    char *name = malloc(8);
    if (!name) return;
    name[0] = 0;
    label_set(l, name);
    free(name);
}
