/* Source-level effect example; this is not a DMA-safety demonstration. */
int board_wait(int ticks);

static int helper(void) { return board_wait(1); }
int irq_entry(void) { return helper(); }
int pure_entry(int value) { return value + 1; }
