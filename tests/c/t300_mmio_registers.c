/* Independently authored inputs: register accesses at constant addresses, written the ways device
   headers usually write them, checked against a register map the test declares. */
typedef unsigned int u32;
typedef unsigned short u16;

#define DEV_BASE 0x40001000u
#define CTRL   (*(volatile u32 *)(DEV_BASE + 0x00))   /* read-write, bits 31..16 reserved (zero) */
#define STATUS (*(volatile u32 *)(DEV_BASE + 0x04))   /* read-only */
#define DATA   (*(volatile u32 *)(DEV_BASE + 0x08))   /* write-only */
#define FLAGS  (*(volatile u32 *)(DEV_BASE + 0x0C))   /* write 1 to clear */
#define EVENTS (*(volatile u32 *)(DEV_BASE + 0x10))   /* read-write, bits 3..0 cleared by reading */
#define MODE   (*(volatile u32 *)(DEV_BASE + 0x14))   /* bits 7..4 reserved (preserve) */
#define GAP    (*(volatile u32 *)(DEV_BASE + 0x40))   /* inside the block, not a register */
#define ELSEWHERE (*(volatile u32 *)0x50000000u)      /* outside every declared block */

typedef struct {
  volatile u32 ctrl;
  volatile u32 status;
  volatile u32 data;
  volatile u32 flags;
} dev_regs;
#define DEV ((dev_regs *)DEV_BASE)

extern void use(u32 v);
extern u32 runtime_value(void);

/* ---- accepted --------------------------------------------------------------------------------- */

void ctrl_write(void) { CTRL = 0x1u; }
void status_read(void) { use(STATUS); }
void status_poll(void) { while ((STATUS & 1u) == 0) { } }
void data_write(void) { DATA = 0x55u; }
void flags_clear(void) { FLAGS = 0x4u; }
void events_read(void) { use(EVENTS); }
void mode_set_bit(void) { MODE |= 0x1u; }
void mode_clear_bit(void) { MODE &= ~0x1u; }
void mode_toggle_bit(void) { MODE ^= 0x1u; }
void struct_write(void) { DEV->ctrl = 0x1u; }
void struct_read(void) { use(DEV->status); }
void direct_cast(void) { *(volatile u32 *)0x40001008u = 7u; }

/* ---- violations ------------------------------------------------------------------------------- */

void status_write(void) { STATUS = 1u; }                 /* MMIO_EXPECT MMIO_READ_ONLY_WRITE */
void data_read(void) { use(DATA); }                      /* MMIO_EXPECT MMIO_WRITE_ONLY_READ */
void data_update(void) { DATA |= 1u; }                   /* MMIO_EXPECT MMIO_WRITE_ONLY_READ */
void flags_update(void) { FLAGS |= 0x4u; }               /* MMIO_EXPECT MMIO_WRITE_ONE_TO_CLEAR_UPDATE */
void events_update(void) { EVENTS &= ~1u; }              /* MMIO_EXPECT MMIO_READ_TO_CLEAR_UPDATE */
void mode_set_reserved(void) { MODE |= 0x10u; }          /* MMIO_EXPECT MMIO_RESERVED_BITS */
void ctrl_reserved(void) { CTRL = 0x10000u; }            /* MMIO_EXPECT MMIO_RESERVED_BITS */
void ctrl_set_reserved(void) { CTRL |= 0x80000000u; }    /* MMIO_EXPECT MMIO_RESERVED_BITS */
void mode_plain_write(void) { MODE = 0x1u; }             /* MMIO_EXPECT MMIO_RESERVED_BITS */
void narrow_access(void) { *(volatile u16 *)(DEV_BASE + 0x02) = 1; }  /* MMIO_EXPECT MMIO_ACCESS_WIDTH */
void gap_write(void) { GAP = 1u; }                       /* MMIO_EXPECT MMIO_UNDECLARED_REGISTER */
void struct_status_write(void) { DEV->status = 1u; }     /* MMIO_EXPECT MMIO_READ_ONLY_WRITE */

/* ---- unverified ------------------------------------------------------------------------------- */

/* reserved bits written as zero: a read-modify-write keeps whatever they read as */
void ctrl_set_bit(void) { CTRL |= 0x2u; }                /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void ctrl_clear_bit(void) { CTRL &= ~0x2u; }             /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void ctrl_toggle_bit(void) { CTRL ^= 0x2u; }             /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void ctrl_toggle_reserved(void) { CTRL ^= 0x10000u; }    /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void ctrl_step(void) { CTRL++; }                         /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void mode_clear_reserved(void) { MODE &= ~0x10u; }       /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void ctrl_runtime(void) { CTRL = runtime_value(); }      /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void ctrl_or_runtime(void) { CTRL |= runtime_value(); }  /* MMIO_EXPECT UNKNOWN_MMIO_RESERVED_BITS */
void elsewhere_write(void) { ELSEWHERE = 1u; }           /* MMIO_EXPECT UNKNOWN_MMIO_ADDRESS */

/* ---- ordering: a start register must follow a barrier after descriptor writes ------------------
   A driver fills a descriptor in memory, then tells the device to start. The register map declares
   that the start register needs a full barrier after earlier memory writes; the checker confirms the
   barrier is on every path. These functions are analysis input only and are never run. */

#define START (*(volatile u32 *)(DEV_BASE + 0x18))      /* write-only, requires a full barrier */
extern void full_barrier(void);
extern void prepare(u32 *descriptor);

void start_after_barrier(void) { u32 d[4]; d[0] = 1u; full_barrier(); START = 1u; use(d[0]); }
void start_without_barrier(void) { u32 d[4]; d[0] = 1u; START = 1u; use(d[0]); }      /* MMIO_EXPECT MMIO_BARRIER_REQUIRED */
void start_after_api_write(void) { u32 d[4]; prepare(d); START = 1u; use(d[0]); }    /* MMIO_EXPECT MMIO_BARRIER_REQUIRED */
void start_after_api_and_barrier(void) { u32 d[4]; prepare(d); full_barrier(); START = 1u; use(d[0]); }
void start_write_on_one_branch(int c) { u32 d[4]; full_barrier(); if (c) d[0] = 1u; START = 1u; }  /* MMIO_EXPECT MMIO_BARRIER_REQUIRED */
void start_at_entry(void) { START = 1u; }                                            /* MMIO_EXPECT UNKNOWN_MMIO_BARRIER */
void start_barrier_first(void) { full_barrier(); START = 1u; }
void start_after_register_write(void) { full_barrier(); CTRL = 1u; START = 1u; }
