/* kenbi overlay for ImageMagick: the project's memory API declared once. Force-included with
   `-include`, so nothing in the project itself is edited. Each family is declared separately —
   aligned allocations must be released by the aligned function. The releases return NULL and
   the house style is `p = Relinquish...(p)`, which `free_returns_null` describes.

   The typed `Acquire…`/`Destroy…` pairs are declared as part of the GENERIC family, which is
   what they are: each destructor frees the object's fields and then ends
   `X = RelinquishMagickMemory(X); return X;`, and the objects themselves are allocated with the
   generic `AcquireMagickMemory` / `AcquireQuantumMemory` — `AcquireKernelInfo` parses a kernel
   out of a string, it is not where the block comes from. Splitting them into per-type families
   was tried and is wrong for this project: `kernel = AcquireMagickMemory(sizeof(*kernel))`
   belongs to the generic family by the only thing the site states, so every
   `DestroyKernelInfo(kernel)` then read as a wrong deallocator (50 of them). Telling those
   apart would need a resource identity based on the TYPE rather than on the allocator's name,
   which is not vocabulary kenbi has. The cost of the generic family is recorded plainly: for
   objects allocated this way WRONG_DEALLOCATOR cannot catch a mismatch between two of the
   project's own destructors.

   STRINGS ARE PLAIN BUFFERS here, so they are in that family too. `DestroyString` is
   `return (char *) RelinquishMagickMemory(string);` and nothing else, so the two names release
   the same block the same way. Declared as a separate family they were not interchangeable, and
   MagickCore's own `token = RelinquishMagickMemory(token)` on an `AcquireString` result — and
   the mirror, `DestroyString` on an `AcquireQuantumMemory` buffer — read as a wrong
   deallocator: 12 findings, every one of them correct C.

   `frees_fields:` records that a destructor releases the object's owned FIELDS as well —
   without it, freeing the container while a field still owns is a LEAK, which is the right
   default for a plain `free(s)` and wrong for a destructor that exists to release the graph.
   Only functions whose bodies were read are listed.

   `@contracts_for` says whose contracts these are and what build they were written against.
   The version is DECLARED (kenbi cannot read a library's version out of source and does not
   pretend to); the build conditions are CHECKED against the compile line, so using this overlay
   on a QUANTUM_DEPTH=8 build says so instead of quietly making promises for another build.

   Declaring them RAISES the finding count (689 -> 729 across the 95 files), and that is the
   closure walking outward, not a regression: a `DestroyKernelInfo(kernel)` call was an
   uncontracted boundary before — kenbi could not see that a release happened there at all, so
   nothing through it was checked — and is now a release it checks, which in turn asks who owns
   the object (29 more `UNCONTRACTED_RELEASE`, each one an intake contract to declare). It also
   found a real leak: `OrderedDitherImage` (threshold.c:1893) acquires a ThresholdMap at 1945
   and returns at 1972 if `SetImageStorageClass` fails, without the `DestroyThresholdMap(map)`
   that every other exit does — the map and its three heap fields leak on that path. */
// @contracts_for ImageMagick { version: 7.1.2-27, requires: MAGICKCORE_QUANTUM_DEPTH=16 MAGICKCORE_HDRI_ENABLE=0 }
// @allocator magick::mem { alloc: AcquireMagickMemory AcquireQuantumMemory AcquireCriticalMemory AcquireKernelInfo CloneKernelInfo AcquireKernelBuiltIn AcquireMatrixInfo GetThresholdMap AcquireStringInfo CloneStringInfo AcquireProfileStringInfo ConvertPathToPolygon AcquireString ConstantString CloneString, realloc: ResizeMagickMemory ResizeQuantumMemory, free_returns_null: RelinquishMagickMemory DestroyString DestroyKernelInfo DestroyMatrixInfo DestroyThresholdMap DestroyPolygonInfo DestroyStringInfo DestroyPixelList, frees_fields: DestroyKernelInfo DestroyMatrixInfo DestroyThresholdMap DestroyPolygonInfo DestroyStringInfo DestroyPixelList }
// @allocator magick::aligned { alloc: AcquireAlignedMemory, free_returns_null: RelinquishAlignedMemory }
