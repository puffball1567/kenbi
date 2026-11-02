// @kenbi
/* STATE C — the kenbi-idiomatic rewrite (GREEN), mirroring the upstream fix ("krb5: avoid
   realloc(0)"): guard the realloc on a non-zero length, so a len==0 never becomes
   realloc(0)=free of buf->data. realloc CONTINUES the field's obligation (kenbi aliases the
   result to buf->data), and the field is released exactly once by the cleanup below. kenbi
   confirms it is safe. This header is >6 lines so @kenbi binds FILE-LEVEL.
   CWE: 415 Double Free — fixed at curl commit 3d6460ed. */
#include <stdlib.h>
struct krb5buffer { char *data; };

void read_data_and_cleanup(struct krb5buffer *buf, int len)
{
    /* @mem g::buf { free: free, owner: data } */
    buf->data = (char *)malloc(256);
    if (buf->data == NULL) { return; }
    if (len != 0) {
        /* FIXED: only realloc when there is a length; len==0 no longer frees buf->data */
        char *tmp = (char *)realloc(buf->data, (size_t)len);   // @realloc
        if (tmp != NULL) { buf->data = tmp; }
    }
    free(buf->data);
}
