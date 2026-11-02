/* STATE A — the arena `pool` is declared (@arena), and `p` is borrowed from it, but it is used
   AFTER `arena_destroy(R)` frees the whole region. kenbi default-reds the expired-pointer use:
   BORROW_OUTLIVES_OWNER. (The bug is contract-relative — it exists once the arena is declared —
   so state A carries @arena; the progression is use-after-destroy -> null-checked-but-still-dead
   -> use-before-destroy.) */
/* CWE: 825 Expired Pointer Dereference (arena pointer used after destroy) */
// @arena pool { create: arena_create, alloc: arena_alloc, free: arena_destroy }
typedef struct arena arena_t;
arena_t *arena_create(void);
void *arena_alloc(arena_t *a, int n);
void arena_destroy(arena_t *a);
// @borrows(p)
void use(char *p);

void CWE825_Expired_Pointer__arena_use_after_destroy_01_bad(void)
{
    arena_t *R = arena_create();
    char *p = (char *)arena_alloc(R, 16);
    arena_destroy(R);
    /* POTENTIAL FLAW: p points into the destroyed arena */
    use(p);
}
