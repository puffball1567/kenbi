// @kenbi
/* STATE B — honestly annotated (the bug is still here). buf->data is a @mem resource owned by the
   field. The len==0 path frees it (realloc(0) semantics) and the cleanup frees it again: with the
   field ownership declared kenbi proves the DOUBLE_FREE through buf->data. The annotation exposes
   the bug, it does not hide it. This header is >6 lines so @kenbi binds FILE-LEVEL.
   CWE: 415 Double Free. Provenance: curl CVE-2016-8619 (commit 3d6460ed). */
#include <stdlib.h>
struct krb5buffer { char *data; };

void read_data_and_cleanup(struct krb5buffer *buf, int len)
{
    /* @mem g::buf { free: free, owner: data } */
    buf->data = (char *)malloc(256);
    if (buf->data == NULL) { return; }
    if (len == 0) {
        free(buf->data);      /* realloc(buf->data, 0) frees it; buf->data left dangling */
    }
    free(buf->data);          /* DOUBLE_FREE through the field on the len==0 path */
}
