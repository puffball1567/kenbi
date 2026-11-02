/* Acceptance fixture for configured low-level verification: a small DMA driver.
 *
 * The API and both devices are synthetic. The source names no device: the project selects a
 * device specification, and the same functions are checked against each one.
 *
 *   dma_configure      stopped -> ready
 *   dma_start_tx       ready   -> busy     the device READS the buffer until the transfer ends
 *   dma_start_rx       ready   -> busy     the device WRITES the buffer until the transfer ends
 *   dma_complete       busy    -> ready    (0) or failed (non-zero); ends the borrow either way
 *   dma_cancel         busy    -> stopping a request only: the device may still access the buffer
 *   dma_wait_stopped   stopping -> ready   the acknowledgement that ends the borrow
 *   dma_reset          failed  -> ready
 *   cache_clean        writes back CPU caches for a buffer before a CPU->device transfer
 *   cache_invalidate   discards CPU cache lines for a buffer a device has written
 */
#include <stdlib.h>

struct dma_chan { unsigned opaque; };

void dma_configure(struct dma_chan *ch);
int dma_start_tx(struct dma_chan *ch, const unsigned char *buf, unsigned len);
int dma_start_rx(struct dma_chan *ch, unsigned char *buf, unsigned len);
int dma_complete(struct dma_chan *ch);
void dma_cancel(struct dma_chan *ch);
void dma_wait_stopped(struct dma_chan *ch);
void dma_reset(struct dma_chan *ch);
void cache_clean(const unsigned char *buf, unsigned len);
void cache_invalidate(unsigned char *buf, unsigned len);
void log_value(int v);

/* Complete a transfer and recover a failed channel, so each scenario below carries only the one
   defect it is about. Visible, so the checker follows it. */
static int finish(struct dma_chan *ch) {
  if (dma_complete(ch) != 0) { dma_reset(ch); return -1; }
  return 0;
}

/* ---- normal operation ------------------------------------------------------------------------ */

int tx_normal(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  buf[0] = 7;
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  if (dma_complete(&ch) != 0) { dma_reset(&ch); return -1; }
  buf[1] = 8;                       /* the transfer has ended: the CPU owns the buffer again */
  return 0;
}

int heap_tx_normal(void) {
  struct dma_chan ch;
  unsigned char *buf = (unsigned char *)malloc(64);
  if (buf == NULL) return -1;
  dma_configure(&ch);
  buf[0] = 7;
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) { free(buf); return -1; }
  int status = finish(&ch);
  free(buf);
  return status;
}

int rx_normal(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64];
  dma_configure(&ch);
  if (dma_start_rx(&ch, buf, 64) != 0) return -1;
  if (dma_complete(&ch) != 0) { dma_reset(&ch); return -1; }
  cache_invalidate(buf, 64);
  log_value(buf[0]);
  return 0;
}

int tx_cancelled(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  dma_cancel(&ch);
  dma_wait_stopped(&ch);            /* only the acknowledgement ends the device's access */
  buf[0] = 1;
  return 0;
}

/* ---- state preconditions --------------------------------------------------------------------- */

int start_before_configure(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  return finish(&ch);
}

int start_while_busy(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char a[64] = {0};
  _Alignas(32) unsigned char b[64] = {0};
  dma_configure(&ch);
  cache_clean(a, 64);
  cache_clean(b, 64);
  if (dma_start_tx(&ch, a, 64) != 0) return -1;
  struct dma_chan *alias = &ch;
  if (dma_start_tx(alias, b, 64) != 0) return -1;
  return finish(&ch);
}

/* ---- the buffer is the device's while the transfer runs -------------------------------------- */

int cpu_write_during_tx(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  buf[0] = 9;
  return finish(&ch);
}

int cpu_read_during_rx(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64];
  dma_configure(&ch);
  if (dma_start_rx(&ch, buf, 64) != 0) return -1;
  log_value(buf[0]);
  return finish(&ch);
}

int buffer_dies_during_tx(void) {
  struct dma_chan ch;
  dma_configure(&ch);
  {
    _Alignas(32) unsigned char buf[64] = {0};
    cache_clean(buf, 64);
    if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  }                                 /* buf's lifetime ends while the device still reads it */
  return finish(&ch);
}

int free_during_tx(void) {
  struct dma_chan ch;
  unsigned char *buf = (unsigned char *)malloc(64);
  if (buf == NULL) return -1;
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) { free(buf); return -1; }
  free(buf);
  return finish(&ch);
}

/* ---- region, range and alignment ------------------------------------------------------------- */

int buffer_too_small(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[16] = {0};
  dma_configure(&ch);
  cache_clean(buf, 16);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  return finish(&ch);
}

int misaligned_offset(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[96] = {0};
  dma_configure(&ch);
  cache_clean(buf + 4, 64);
  if (dma_start_tx(&ch, buf + 4, 64) != 0) return -1;   /* 4-aligned, not 32-aligned */
  return finish(&ch);
}

int buffer_alignment_unknown(void) {
  struct dma_chan ch;
  unsigned char buf[64] = {0};             /* no alignment guarantee beyond 1 */
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  return finish(&ch);
}

/* ---- cache maintenance ----------------------------------------------------------------------- */

int tx_without_cache_clean(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  buf[0] = 3;
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  return finish(&ch);
}

int write_after_cache_clean(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 64);
  buf[0] = 3;                       /* dirties the line the clean just wrote back */
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  return finish(&ch);
}

int partial_cache_clean(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 16);                    /* only the first 16 of the 64 transferred bytes */
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  return finish(&ch);
}

int rx_read_without_invalidate(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64];
  dma_configure(&ch);
  if (dma_start_rx(&ch, buf, 64) != 0) return -1;
  if (finish(&ch) != 0) return -1;
  log_value(buf[0]);                       /* the CPU may see stale cache lines */
  return 0;
}

/* ---- recovery on every exit ------------------------------------------------------------------ */

int failure_not_reset(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  if (dma_complete(&ch) != 0) return -1;   /* the channel is left failed */
  return 0;
}

int early_return_while_busy(int abort_now) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  if (abort_now) return -2;                /* leaves with the transfer running */
  return finish(&ch);
}

int cancel_without_ack(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  dma_cancel(&ch);
  buf[0] = 1;                              /* the device may still be reading */
  return 0;
}

/* ---- joins and loops ------------------------------------------------------------------------- */

int complete_on_one_branch(int fast) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  if (fast) {
    if (dma_complete(&ch) != 0) { dma_reset(&ch); return -1; }
  }
  buf[0] = 1;                              /* busy on the other path */
  return 0;
}

int restart_in_loop(int n) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  for (int i = 0; i < n; i++) {
    cache_clean(buf, 64);
    if (dma_start_tx(&ch, buf, 64) != 0) return -1;   /* second iteration: still busy */
  }
  return 0;
}

/* ---- execution context ----------------------------------------------------------------------- */

static void refill(void) {
  unsigned char *more = (unsigned char *)malloc(32);
  if (more != NULL) free(more);
}

void dma_irq_handler(void) {
  refill();                                /* allocation reached from interrupt context */
}

/* ---- a function nothing specifies ------------------------------------------------------------ */

void undocumented_vendor_call(struct dma_chan *ch);

int uses_uncontracted_api(void) {
  struct dma_chan ch;
  _Alignas(32) unsigned char buf[64] = {0};
  dma_configure(&ch);
  undocumented_vendor_call(&ch);
  cache_clean(buf, 64);
  if (dma_start_tx(&ch, buf, 64) != 0) return -1;
  return finish(&ch);
}
