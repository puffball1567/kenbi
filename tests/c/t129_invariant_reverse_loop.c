// @spatial
// INVARIANT — the reverse-loop idiom `for (i = field - 1; i >= 0; i--)` (jsmn's token
// rewind). The init `i = toknext - 1` establishes the SYMBOLIC upper bound `i < toknext`
// (a signed `i = term - k` is mathematically < term; the `i >= 0` loop guard supplies the
// lower bound, the same deferred concern as every signed index). Hoisted before the loop,
// the bound reaches `tokens[i]`, and the invariant chains it to the buffer's size:
// `i < toknext <= num_tokens`. An UNSIGNED target is NOT derived (it could wrap to a huge
// value) — that stays red, so no false green.
#include <stddef.h>

struct Tok { int v; };

// `i = toknext - 1` into a SIGNED `i`: i < toknext, chained to num_tokens — every tokens[i]
// in the rewind is covered.
// @counted_by(tokens: num_tokens)
// @invariant(p_toknext <= num_tokens)
void rewind_ok(unsigned int p_toknext, struct Tok *tokens, unsigned int num_tokens) {
  int i;
  for (i = p_toknext - 1; i >= 0; i--) {
    tokens[i].v = 1;           // i < toknext <= num_tokens — covered (signed reverse loop)
  }
}

// The SAME loop but `i` is UNSIGNED: `toknext - 1` can wrap to UINT_MAX, so the bound is NOT
// derived and the access stays red (kenbi refuses the unsound green).
// @counted_by(tokens: num_tokens)
// @invariant(p_toknext <= num_tokens)
void rewind_unsigned_red(unsigned int p_toknext, struct Tok *tokens, unsigned int num_tokens) {
  unsigned int i;
  for (i = p_toknext - 1; i + 1 >= 1; i--) {
    tokens[i].v = 1;           //EXPECT UNVALIDATED_INDEX
  }
}
