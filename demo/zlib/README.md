# Applying kenbi to zlib without touching it

zlib does not call an allocator by name: every allocation goes through the function pointers a
caller installs in the `z_stream` — `ZALLOC(strm, items, size)` expands to
`(*((strm)->zalloc))(…)`. sqlite, lua and most embedded APIs are shaped the same way.

[`kenbi_zlib_mem.h`](kenbi_zlib_mem.h) declares that family by naming the FIELDS, in one line.
It is comments only, so it can be force-included: **zlib itself is not edited.**

```sh
Z=/path/to/zlib
for f in "$Z"/*.c; do
  kenbi --format=json "$f" -- -I "$Z" -include "$(pwd)/demo/zlib/kenbi_zlib_mem.h"
done
```

Result on zlib 1.3 (15 files, un-annotated apart from that one line): **10 findings, none of
them a bug claim** — four `UNCONTRACTED_RELEASE` and one `UNCONTRACTED_ESCAPE` (boundaries
whose contract is not declared), one `UNKNOWN_RESOURCE` (an undeclared `malloc`), one
`POSSIBLE_USE_AFTER_FREE` advisory, and two `UNSTRUCTURED_GOTO` in `inffast.c`, whose
hand-written goto loop kenbi refuses to model rather than guess at.
