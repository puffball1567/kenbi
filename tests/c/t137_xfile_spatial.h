// Companion header for t137: the SPATIAL contracts are declared HERE (on the prototypes);
// kenbi resolves them against the implementation's params in t137_xfile_spatial.c (a different
// TU), so @counted_by / @invariant bind cross-file (operands resolved by name, not USR).
typedef struct { int *data; unsigned int cap; unsigned int len; } Vec137;

// @counted_by(v->data: v->cap)
// @invariant(v->len <= v->cap)
int vec137_get(const Vec137 *v, unsigned int i, int *out);

// @counted_by(v->data: v->cap)
int vec137_unchecked(const Vec137 *v, unsigned int i, int *out);
