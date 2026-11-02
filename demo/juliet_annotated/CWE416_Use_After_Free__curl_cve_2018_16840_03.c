// @kenbi
/* STATE B — honestly annotated: `curl_multi_cleanup` @frees the handle (as it really does), and
   the handle is owned by `m`. Using it afterwards is a use-after-free — the reason converges to
   USE_AFTER_FREE. This is the real CVE-2018-16840 bug: Curl_close cleaned up the multi handle and
   then a later path still touched it (the pointer was not nulled). */
/* CWE: 416 Use After Free — curl CVE-2018-16840. */
#include <stdlib.h>
struct Curl_multi { int dummy; };
// @frees(m)
void curl_multi_cleanup(struct Curl_multi *m);
// @borrows(m)
void use_multi(struct Curl_multi *m);

void Curl_close_bad(void)
{
    /* @mem lib::multi { free: curl_multi_cleanup, owner: m } */
    struct Curl_multi *m = (struct Curl_multi *)malloc(sizeof *m);
    if (!m) { return; }
    curl_multi_cleanup(m);
    /* POTENTIAL FLAW: the handle was just cleaned up */
    use_multi(m);
}
