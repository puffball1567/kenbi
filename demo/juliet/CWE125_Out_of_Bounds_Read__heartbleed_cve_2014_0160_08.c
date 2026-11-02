// @spatial
/* STATE A — adopted, but `payload` (a 16-bit length from the peer) bytes are copied from the
   record `pl`, which holds only `rrec_length` bytes, with NO bound relating payload to the record
   length. kenbi flags the SOURCE over-read: UNVALIDATED_SIZE. This is Heartbleed (CVE-2014-0160):
   tls1_process_heartbeat copied `payload` bytes with no check, disclosing up to ~64KB. */
/* CWE: 125 Out-of-bounds Read — OpenSSL Heartbleed (memcpy source over-read). */
#include <string.h>
// @counted_by(pl: rrec_length)
// @counted_by(bp: rrec_length)
int tls1_process_heartbeat_bad(const unsigned char *pl, unsigned rrec_length, unsigned char *bp, unsigned payload) {
    memcpy(bp, pl, payload);   /* POTENTIAL FLAW: payload not bounded by rrec_length */
    return 0;
}
