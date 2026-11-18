// @typecheck
// SWITCH FALL-THROUGH, tagged unions. A `case VALUE:` proves `tag == VALUE` for the code entered
// at it — including the groups it falls through into, whose own labels prove nothing on that
// path. Reading the variant a later label names, after falling into it, is TYPE_CONFUSION.
typedef struct {
  int tag;                          // 0 = integer, 1 = pointer
  union { int i; char *p; } u;
} Node;

// case 0 falls into case 1's read of `.p`: on that path tag == 0
// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
long fall_wrong(Node *n) {
  long r = 0;
  switch (n->tag) {
    case 0:
      r = n->u.i;
      /* fall through */
    case 1:
      r += (long)n->u.p;            //EXPECT TYPE_CONFUSION
      break;
    default:
      r = -1;
  }
  return r;
}

// the same reads with a `break`: each case reads its own variant — clean
// @variant(n->u.i: n->tag == 0)
// @variant(n->u.p: n->tag == 1)
long no_fall(Node *n) {
  long r = 0;
  switch (n->tag) {
    case 0:
      r = n->u.i;
      break;
    case 1:
      r = (long)n->u.p;
      break;
    default:
      r = -1;
  }
  return r;
}
