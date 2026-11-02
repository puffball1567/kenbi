/* kenbi overlay for zlib: the allocator zlib is GIVEN, not the one it calls. Every zlib
   allocation goes through the function pointers a caller installs in the z_stream
   (`ZALLOC(strm,…)` expands to `(*((strm)->zalloc))(…)`), so the declaration names those
   FIELDS — the same shape sqlite, lua and most embedded APIs use. Comments only: nothing in
   zlib is edited, force-include this with `-include`. */
// @allocator zlib::mem { alloc: zalloc, free: zfree }
