/* STATE A — un-annotated. Minimal reproduction of curl's CVE-2016-8619 (krb5 read_data): a
   16-bit length is read from the server; `realloc(buf->data, len)` with len==0 acts as
   free(buf->data) and returns NULL, and read_data returns error WITHOUT clearing buf->data — so
   the krb5 connection cleanup frees the field a second time. A double free through buf->data.
   CWE: 415 Double Free. Provenance: curl commit 3d6460ed "krb5: avoid realloc(0)". */
#include <stdlib.h>
struct krb5buffer { char *data; };

void read_data_and_cleanup(struct krb5buffer *buf, int len)
{
    buf->data = (char *)malloc(256);
    if (buf->data == NULL) { return; }
    if (len == 0) {
        /* realloc(buf->data, 0) frees buf->data and returns NULL; buf->data is left dangling */
        free(buf->data);
    }
    /* krb5 cleanup frees the field again — a double free on the len==0 path */
    free(buf->data);
}
