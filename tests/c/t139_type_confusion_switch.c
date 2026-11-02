// @typecheck
// TYPE-CONFUSION V2: a `switch (tag)` dispatches the discriminant — each `case VALUE:` proves
// `tag == VALUE` in its body, so reading the matching `@variant` member there is safe. The
// idiomatic way to consume a tagged union (the C analogue of a Rust `match` on an enum).
typedef struct {
  int tag;                          // 0 = integer, 1 = pointer
  union { int i; char *p; } u;
} Node;

// (1) GREEN: a switch on the discriminant; each case reads its own variant.
// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
long consume(Node *n) {
  switch (n->tag) {
    case 0: return n->u.i;          // tag == 0 proven by the case — ok
    case 1: return (long)n->u.p;    // tag == 1 proven by the case — ok
    default: return -1;
  }
}

// (2) RED: a case reads the WRONG variant — case 0 proves tag == 0, but reads `.p` (needs == 1).
// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
long consume_wrong(Node *n) {
  switch (n->tag) {
    case 0: return (long)n->u.p;    //EXPECT TYPE_CONFUSION
    default: return -1;
  }
}
