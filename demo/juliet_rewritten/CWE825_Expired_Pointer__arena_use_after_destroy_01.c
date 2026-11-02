/* STATE C — the borrowed pointer is used BEFORE the arena is destroyed, so it never outlives its
   owner. GREEN. */
/* CWE: 825 Expired Pointer Dereference — fixed by using before destroy. */
// @arena pool { create: arena_create, alloc: arena_alloc, free: arena_destroy }
typedef struct arena arena_t;
arena_t *arena_create(void);
void *arena_alloc(arena_t *a, int n);
void arena_destroy(arena_t *a);
// @borrows(p)
void use(char *p);

void CWE825_Expired_Pointer__arena_use_after_destroy_01_fixed(void)
{
    arena_t *R = arena_create();
    char *p = (char *)arena_alloc(R, 16);
    use(p);              /* FIXED: use before destroy */
    arena_destroy(R);
}
