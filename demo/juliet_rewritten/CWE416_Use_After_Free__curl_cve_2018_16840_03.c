// @kenbi
/* STATE C — the handle is used BEFORE it is cleaned up, so no access outlives the free. GREEN.
   (The upstream fix instead nulls `data->multi_easy` right after cleanup so the later re-entrant
   path skips it; using-before-cleanup is the equivalent safe ordering.) */
/* CWE: 416 Use After Free — curl CVE-2018-16840, fixed. */
#include <stdlib.h>
struct Curl_multi { int dummy; };
// @frees(m)
void curl_multi_cleanup(struct Curl_multi *m);
// @borrows(m)
void use_multi(struct Curl_multi *m);

void Curl_close_fixed(void)
{
    /* @mem lib::multi { free: curl_multi_cleanup, owner: m } */
    struct Curl_multi *m = (struct Curl_multi *)malloc(sizeof *m);
    if (!m) { return; }
    use_multi(m);              /* FIXED: use before cleanup */
    curl_multi_cleanup(m);
}
