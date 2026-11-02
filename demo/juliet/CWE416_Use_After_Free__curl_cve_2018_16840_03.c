/* STATE A — un-annotated. `curl_multi_cleanup` frees the handle, but with no @frees contract
   kenbi cannot see the release across the boundary: the owned handle escaping to uncontracted
   callees is a generic UNCONTRACTED_ESCAPE, not yet a use-after-free diagnosis. */
/* CWE: 416 Use After Free — curl CVE-2018-16840 (Curl_close used a cleaned-up multi handle). */
#include <stdlib.h>
struct Curl_multi { int dummy; };
void curl_multi_cleanup(struct Curl_multi *m);
void use_multi(struct Curl_multi *m);

void Curl_close_bad(void)
{
    struct Curl_multi *m = (struct Curl_multi *)malloc(sizeof *m);
    if (!m) { return; }
    curl_multi_cleanup(m);
    use_multi(m);
}
