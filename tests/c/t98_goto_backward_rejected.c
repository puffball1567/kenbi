// A BACKWARD goto (a goto-loop) is NOT modelable by the forward join-merge: control can
// re-enter an earlier label an unknown number of times, so ownership across the back-edge
// is not statically trackable. kenbi REFUSES it (UNSTRUCTURED_GOTO) rather than pretend a
// single pass models the loop — a free reached only on a later iteration must not slip
// past as a false GREEN. The fix is to restructure into a real loop (bounded fixpoint is
// a later increment) or a forward cleanup ladder.
void f(int n) {
again:
  n--;
  if (n > 0) goto again;   //EXPECT UNSTRUCTURED_GOTO
}
