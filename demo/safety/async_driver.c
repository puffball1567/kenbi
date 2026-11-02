/* Original synthetic API. This is not a hardware-specific DMA driver. */
struct transfer { unsigned opaque; };
void transfer_init(struct transfer *t);
void transfer_start(struct transfer *t, unsigned char *buffer);
void transfer_finish(struct transfer *t);

void completed(void) {
  struct transfer t;
  unsigned char buffer[16] = {0};
  transfer_init(&t);
  transfer_start(&t, buffer);
  transfer_finish(&t);
  buffer[0] = 1;
}

int read_during_transfer(void) {
  struct transfer t;
  unsigned char buffer[16] = {0};
  transfer_init(&t);
  transfer_start(&t, buffer);
  int value = buffer[0];
  transfer_finish(&t);
  return value;
}
