// @spatial
// SPATIAL self inc/dec of an @invariant field + post-decrement strictness (the Rust `Vec` port
// idiom — push/pop). `len = len + 1` is a SET form of `len += 1` and is verified to MAINTAIN
// `len <= cap` like a compound increment. `len = len - 1` (a decrement) TIGHTENS the field to
// `len < cap` for the immediately-following `data[len]` access (the `arr[len-1]` last-element
// idiom) — SOUND only when `len` is known `>= 1` on the path (no unsigned underflow).
typedef struct { int *data; unsigned int cap; unsigned int len; } Vec;

// (1) GREEN: push — a SET-form increment `len = len + 1` under `len < cap` maintains len <= cap.
// @counted_by(v->data: v->cap)
// @invariant(v->len <= v->cap)
int push(Vec *v, int x) {
  if (v->len < v->cap) {
    v->data[v->len] = x;               // len < cap — in bounds
    v->len = v->len + 1;               // @maintains(v->len <= v->cap)  — SET-form increment
    return 1;
  }
  return 0;
}

// (2) GREEN: pop — `len = len - 1` guarded by `len > 0` (so len >= 1, no underflow); the
// post-decrement bound makes the last-element read data[len] strictly `< cap`.
// @counted_by(v->data: v->cap)
// @invariant(v->len <= v->cap)
int pop(Vec *v, int *out) {
  if (v->len > 0) {
    v->len = v->len - 1;               // @maintains(v->len <= v->cap)
    *out = v->data[v->len];            // len (post-dec) < cap — last element, in bounds
    return 1;
  }
  return 0;
}

// (3) RED soundness: a decrement WITHOUT the `len > 0` guard — unsigned `len - 1` underflows when
// len == 0 (to a huge value), so data[len] after it is NOT provably in range. Default-red.
// @counted_by(v->data: v->cap)
// @invariant(v->len <= v->cap)
int pop_unguarded(Vec *v, int *out) {
  v->len = v->len - 1;                 // @maintains(v->len <= v->cap)  — still preserves <= cap
  *out = v->data[v->len];              //EXPECT INAPPROPRIATE_BOUND
  return 1;
}
