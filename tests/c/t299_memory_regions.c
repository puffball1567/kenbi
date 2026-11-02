/* Independently authored inputs: a device that may only reach storage in regions with declared
   properties, and buffers whose placement comes from declarations. */
typedef unsigned long size_t;
void *get_dma(size_t n);
void *get_fast(size_t n);
void *get_anywhere(size_t n);
void put(void *p);
void start(int *t, const void *b);
void finish(int *t);

int automatic_buffer(void) { int t; char b[16]; start(&t, b); finish(&t); return 0; }
int automatic_scalar(void) { int t; long v = 0; start(&t, &v); finish(&t); return 0; }
static void send(int *t, const char *b) { start(t, b); finish(t); }
int automatic_through_helper(void) { int t; char b[16]; send(&t, b); return 0; }
int dma_allocation(void) { int t; char *p = get_dma(16); if (!p) return 0; start(&t, p); finish(&t); put(p); return 0; }
int fast_allocation(void) { int t; char *p = get_fast(16); if (!p) return 0; start(&t, p); finish(&t); put(p); return 0; }
int unplaced_allocation(void) { int t; char *p = get_anywhere(16); if (!p) return 0; start(&t, p); finish(&t); put(p); return 0; }
int allocation_offset(void) { int t; char *p = get_dma(32); if (!p) return 0; start(&t, p + 16); finish(&t); put(p); return 0; }
