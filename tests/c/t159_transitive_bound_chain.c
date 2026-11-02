// @spatial
// SPATIAL transitive bound chaining. An index bounded by a VARIABLE (`i < count`) is validated
// against a buffer when that variable is itself bounded by the buffer's own count (`count <= n`)
// — the everyday `i < count <= capacity` idiom (a parser validates a count against the buffer
// size, then iterates up to it). kenbi chains `i < count` with count's OWN validated runtime
// bound `count <= n` to reach `i < n`. Only WRAP-SAFE bounds chain: an unrelated or wrap-prone
// `count` bound does not (it may not hold at runtime). This header keeps @spatial file-level so
// every function below is analysed.
extern void use(int);

// GREEN: i < count, and count <= n (buf's counted_by) — chains to i < n.
// @counted_by(buf: n)
void chain_ok(const int *buf, unsigned n, unsigned count) {
  if (count <= n)
    for (unsigned i = 0; i < count; i++) use(buf[i]);
}

// RED: count is bounded by an UNRELATED variable, not the buffer's count — no chain.
// @counted_by(buf: n)
void chain_wrong_var(const int *buf, unsigned n, unsigned count, unsigned other) {
  if (count <= other)
    for (unsigned i = 0; i < count; i++) use(buf[i]);   //EXPECT UNVALIDATED_INDEX
}

// RED: count is bounded by a WRAP-PRONE form (`count + 1 <= n` wraps for unsigned count near the
// max), so its bound may not hold and does not chain.
// @counted_by(buf: n)
void chain_wrap_prone(const int *buf, unsigned n, unsigned count) {
  if (count + 1 <= n)
    for (unsigned i = 0; i < count; i++) use(buf[i]);   //EXPECT UNVALIDATED_INDEX
}
