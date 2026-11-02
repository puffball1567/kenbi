// @spatial
/* STATE B — a half-fix that mirrors the FIRST guard the patch added: a minimum-size check
   (`1 + 2 + 16 > rrec_length`, i.e. the record must hold the heartbeat header). But it does NOT
   bound `payload`, which still reaches memcpy unchecked. STILL UNVALIDATED_SIZE — checking the
   header size is not checking the payload length. */
/* CWE: 125 Out-of-bounds Read — OpenSSL Heartbleed. */
#include <string.h>
// @counted_by(pl: rrec_length)
// @counted_by(bp: rrec_length)
int tls1_process_heartbeat_bad(const unsigned char *pl, unsigned rrec_length, unsigned char *bp, unsigned payload) {
    if (rrec_length < 19) return 0;    /* POTENTIAL FLAW: header-size check does not bound payload */
    memcpy(bp, pl, payload);
    return 0;
}
