// @typecheck
// TYPE-CONFUSION (tagged union) GATING. A union member declared `@variant(member : tag == value)`
// may be read/written only when the discriminant `tag == value` is PROVEN on the path (an
// `if (tag == value)` guard). Accessing a variant whose tag was not checked is TYPE_CONFUSION —
// the C analogue of a Rust enum's checked discriminant. A MUST-analysis (intersection joins);
// default-red; opt-in via `@typecheck`.
typedef struct {
  int tag;                          // 0 = integer, 1 = pointer
  union { int i; char *p; } u;
} Node;

// (1) GREEN: the discriminant is checked before reading the matching member.
// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
int get_int(Node *n) {
  if (n->tag == 0) {
    return n->u.i;                  // tag proven == 0 — the active variant — ok
  }
  return -1;
}

// (2) RED: read a union member with NO discriminant check — may interpret the wrong member.
// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
char *get_ptr_unchecked(Node *n) {
  return n->u.p;                    //EXPECT TYPE_CONFUSION
}

// (3) RED: the tag is checked, but to the WRONG value — reading `.i` needs tag == 0, not == 1.
// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
int wrong_variant(Node *n) {
  if (n->tag == 1) {
    return n->u.i;                  //EXPECT TYPE_CONFUSION
  }
  return 0;
}
