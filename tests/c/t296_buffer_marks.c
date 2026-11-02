/* Buffer marks: named facts about byte ranges of a storage object, established by external
 * operations, ended by CPU accesses, required when a borrow starts and able to forbid CPU
 * accesses. The API is synthetic; the specifications live in tests/run_tests_marks.py.
 *
 *   prepare(p, n)   sets    "prepared" on n bytes from p   (cleared by a CPU write)
 *   discard(p, n)   clears  "stale"    on n bytes from p   ("stale" forbids a CPU read)
 *   send(ch, p, n)  borrows n bytes from p for reading and requires "prepared" on them
 *   recv(ch, p, n)  borrows n bytes from p for writing and leaves them "stale" when it ends
 *   done(ch)        ends the borrow
 */
struct chan { unsigned opaque; };
void open_chan(struct chan *ch);
int send(struct chan *ch, const unsigned char *p, unsigned n);
int recv(struct chan *ch, unsigned char *p, unsigned n);
void done(struct chan *ch);
void prepare(const unsigned char *p, unsigned n);
void discard(unsigned char *p, unsigned n);
void use(int v);
int runtime_length(void);

/* ---- requirements at borrow start ------------------------------------------------------------- */

void prepared_whole(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 32);
  if (send(&ch, buf, 32) != 0) return;
  done(&ch);
}

void prepared_in_two_pieces(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 16);
  prepare(buf + 16, 16);             /* two adjacent ranges cover the transfer */
  if (send(&ch, buf, 32) != 0) return;
  done(&ch);
}

void prepared_by_sizeof(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, sizeof(buf));
  if (send(&ch, buf, sizeof(buf)) != 0) return;
  done(&ch);
}

void only_the_sent_part_prepared(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 8);
  if (send(&ch, buf, 8) != 0) return;   /* only 8 bytes are sent */
  done(&ch);
}

void never_prepared(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  if (send(&ch, buf, 32) != 0) return;  /* MARK_EXPECT BORROW_MARK_REQUIRED */
  done(&ch);
}

void prepared_too_little(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 16);
  if (send(&ch, buf, 32) != 0) return;  /* MARK_EXPECT BORROW_MARK_REQUIRED */
  done(&ch);
}

void written_after_prepare(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 32);
  buf[20] = 1;
  if (send(&ch, buf, 32) != 0) return;  /* MARK_EXPECT BORROW_MARK_REQUIRED */
  done(&ch);
}

void written_outside_the_sent_bytes(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 16);
  buf[20] = 1;                           /* not among the 16 bytes sent */
  if (send(&ch, buf, 16) != 0) return;
  done(&ch);
}

void written_then_prepared_again(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 32);
  buf[3] = 1;
  prepare(buf, 32);
  if (send(&ch, buf, 32) != 0) return;
  done(&ch);
}

void read_does_not_unprepare(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare(buf, 32);
  use(buf[3]);
  if (send(&ch, buf, 32) != 0) return;
  done(&ch);
}

void prepare_length_unknown(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  int n = runtime_length();
  open_chan(&ch);
  prepare(buf, n);
  if (send(&ch, buf, 32) != 0) return;  /* MARK_EXPECT UNKNOWN_BORROW_MARK */
  done(&ch);
}

void send_length_unknown(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  int n = runtime_length();
  prepare(buf, 16);
  if (send(&ch, buf, n) != 0) return;   /* MARK_EXPECT UNKNOWN_BORROW_MARK */
  done(&ch);
}

static void prepare_helper(const unsigned char *p) { prepare(p, 32); }

void prepared_through_a_helper(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  prepare_helper(buf);
  if (send(&ch, buf, 32) != 0) return;
  done(&ch);
}

void prepared_on_one_branch(int fast) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  if (fast) prepare(buf, 32);
  if (send(&ch, buf, 32) != 0) return;  /* MARK_EXPECT BORROW_MARK_REQUIRED */
  done(&ch);
}

void other_buffer_prepared(void) {
  struct chan ch;
  _Alignas(8) unsigned char a[32] = {0};
  _Alignas(8) unsigned char b[32] = {0};
  open_chan(&ch);
  prepare(a, 32);
  if (send(&ch, b, 32) != 0) return;    /* MARK_EXPECT BORROW_MARK_REQUIRED */
  done(&ch);
}

void new_lifetime_is_unprepared(int n) {
  struct chan ch;
  open_chan(&ch);
  for (unsigned i = 0; i < 2; i++) {
    _Alignas(8) unsigned char buf[32] = {0};
    if (i == 0) prepare(buf, 32);
    if (send(&ch, buf, 32) != 0) return;  /* MARK_EXPECT BORROW_MARK_REQUIRED */
    done(&ch);
  }
  (void)n;
}

/* ---- marks left by a borrow, and prohibitions ------------------------------------------------- */

void received_then_discarded(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32];
  open_chan(&ch);
  if (recv(&ch, buf, 32) != 0) return;
  done(&ch);
  discard(buf, 32);
  use(buf[0]);
}

void received_and_read(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32];
  open_chan(&ch);
  if (recv(&ch, buf, 32) != 0) return;
  done(&ch);
  use(buf[0]);                           /* MARK_EXPECT MARK_FORBIDS_ACCESS */
}

void discarded_too_little(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32];
  open_chan(&ch);
  if (recv(&ch, buf, 32) != 0) return;
  done(&ch);
  discard(buf, 8);
  use(buf[4]);
  use(buf[12]);                          /* MARK_EXPECT MARK_FORBIDS_ACCESS */
}

void read_outside_the_received_bytes(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32] = {0};
  open_chan(&ch);
  if (recv(&ch, buf, 16) != 0) return;
  done(&ch);
  use(buf[20]);                          /* the device wrote only the first 16 bytes */
}

void write_is_not_forbidden(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32];
  open_chan(&ch);
  if (recv(&ch, buf, 32) != 0) return;
  done(&ch);
  buf[0] = 1;
}

void discard_length_unknown(void) {
  struct chan ch;
  _Alignas(8) unsigned char buf[32];
  open_chan(&ch);
  if (recv(&ch, buf, 32) != 0) return;
  done(&ch);
  int n = runtime_length();
  discard(buf, n);
  use(buf[0]);                           /* MARK_EXPECT UNKNOWN_MARK_ACCESS */
}

void not_received_is_not_stale(void) {
  _Alignas(8) unsigned char buf[32] = {0};
  use(buf[0]);
}
