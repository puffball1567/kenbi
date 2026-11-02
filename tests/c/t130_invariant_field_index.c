// @spatial
// INVARIANT — indexing a buffer BY a protected field (jsmn's `tokens[parser->toksuper]`),
// and the flow-sensitive / field-unsigned establish checks that keep the field's invariant
// trustworthy. `toksuper` is itself a protected field (`toksuper < toknext`), so an access
// `tokens[toksuper]` is seeded from its own invariant and chained: toksuper < toknext <=
// num_tokens. The seed is sound only because EVERY write to toksuper is verified to
// maintain `toksuper < toknext`:
//   * `= toknext - 1`  — size ± k (k < 0), established directly;
//   * `= -1`           — needs `toknext` known >= 0: it is an UNSIGNED field, recognised;
//   * `= i` (i bounded by toknext on the path) — verified flow-sensitively.
#include <stddef.h>

struct Tok { int v; };
struct Parser { unsigned int toknext; int toksuper; };

// @counted_by(tokens: num_tokens)
// @invariant(p->toknext <= num_tokens)
// @invariant(p->toksuper < p->toknext)
void step(struct Parser *p, struct Tok *tokens, unsigned int num_tokens) {
  int i;
  p->toksuper = p->toknext - 1;   // @maintains(p->toksuper < p->toknext)   (size - 1)
  p->toksuper = -1;               // @maintains(p->toksuper < p->toknext)   (-1, toknext unsigned)
  for (i = p->toknext - 1; i >= 0; i--) {
    p->toksuper = i;              // @maintains(p->toksuper < p->toknext)   (i < toknext on path)
  }
  if (p->toksuper >= 0) {
    tokens[p->toksuper].v = 1;    // toksuper < toknext <= num_tokens — covered via the seed
  }
}
