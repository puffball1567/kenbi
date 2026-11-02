// Advisory: lock discipline the deterministic engine does not decide — it is
// surfaced for the AI/human reviewer.
struct S {
  int count; // @guarded_by(mutex_)   //EXPECT GUARDED_BY
};
