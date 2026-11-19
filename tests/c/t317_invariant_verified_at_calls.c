// @spatial
// A PARAMETER INVARIANT IS VERIFIED WHERE THE FUNCTION IS CALLED. `@invariant(next <= num)`
// between two parameters is what the body assumes of them; it holds only if every call
// passes arguments that satisfy it. Each call must establish the relation: the same variable
// on both sides, a check on the path, constants, or the caller's own declared invariant.
struct Tok { int v; };
unsigned read_count(void);

// @spatial
// @counted_by(tokens: num)
// @invariant(next <= num)
int last_token(struct Tok *tokens, unsigned next, unsigned num) {
  if (next >= 1) return tokens[next - 1].v;
  return 0;
}

// calls that do not establish it
// @spatial
int calls_unproven(struct Tok *t, unsigned a, unsigned b) {
  int r = last_token(t, a, b);                  //EXPECT INVARIANT_NOT_MAINTAINED
  r += last_token(t, 3, b);                     //EXPECT INVARIANT_NOT_MAINTAINED
  if (a < b) r += last_token(t, a + 2, b);      //EXPECT INVARIANT_NOT_MAINTAINED
  r += last_token(t, read_count(), b);          //EXPECT INVARIANT_NOT_MAINTAINED
  r += last_token(t, 5, 4);                     //EXPECT INVARIANT_NOT_MAINTAINED
  return r;
}

// calls that do — clean
// @spatial
int calls_proven(struct Tok *t, unsigned a, unsigned b) {
  int r = last_token(t, b, b);
  r += last_token(t, 0, b);
  if (a <= b) r += last_token(t, a, b);
  if (a < b) r += last_token(t, a + 1, b);
  if (b >= 3) r += last_token(t, 3, b);
  r += last_token(t, 2, 4);
  return r;
}

// the caller declares the same invariant, and is verified at its own calls in turn — clean
// @spatial
// @invariant(x <= y)
int forward(struct Tok *t, unsigned x, unsigned y) { return last_token(t, x, y); }
