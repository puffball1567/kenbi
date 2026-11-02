// @spatial
/* STATE C — `payload` is bounded against the record length with the 19-byte (1+2+16) heartbeat
   overhead, so the copy cannot read past the record. GREEN. (The upstream fix wrote the guard as
   `1 + 2 + payload + 16 > rrec.length` — kenbi flags THAT expression as overflow-unsafe, since
   `payload + 19` can wrap; this overflow-safe form keeps the arithmetic off the untrusted
   payload.) */
/* CWE: 125 Out-of-bounds Read — OpenSSL Heartbleed, fixed. */
#include <string.h>
// @counted_by(pl: rrec_length)
// @counted_by(bp: rrec_length)
int tls1_process_heartbeat_fixed(const unsigned char *pl, unsigned rrec_length, unsigned char *bp, unsigned payload) {
    if (rrec_length >= 19 && payload <= rrec_length - 19)
        memcpy(bp, pl, payload);
    return 0;
}
