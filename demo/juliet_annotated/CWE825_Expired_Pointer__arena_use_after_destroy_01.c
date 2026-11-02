/* STATE B — a half-fix: a null check is added before the use, but a non-null `p` still points
   into the DESTROYED arena region — the check does not revive freed memory. STILL
   BORROW_OUTLIVES_OWNER. */
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
    /* POTENTIAL FLAW: p still dangles into the destroyed arena, null check or not */
    if (p != 0) { use(p); }
}
