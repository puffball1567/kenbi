/* kenbi overlay for ImageMagick — what the project's functions do with a pointer they are
 * GIVEN, declared BY NAME. Comments only, so it is force-included with `-include` and nothing
 * in ImageMagick is edited.
 *
 * The inline annotations (`// @borrows(p)` above the declaration) cannot reach a project you
 * may not edit: there is nowhere to put the comment. `@contract <Fn> { … }` names the function
 * instead. Parameters are named by POSITION (`$1`, 1-based) because these headers declare them
 * unnamed — `DestroyKernelInfo(KernelInfo *)` — and the call sites that need the contract are
 * in the files that see only that prototype.
 *
 * These are claims kenbi CHECKS, not switches that silence it. A `borrows:` declaration says
 * the callee does not take ownership, so the caller still owes the release — declaring it turns
 * "I cannot tell what happens here" into a decidable obligation, and two new `LEAK`s appeared
 * on this list for exactly that reason. A `frees:` declaration carries a body obligation:
 * declared on a function whose body is in the same translation unit and does not free, it is
 * CONTRACT_NOT_HONORED.
 *
 * Measured on MagickCore (95 files, `-fopenmp`, with the memory and list overlays):
 * 657 -> 626 error findings, UNCONTRACTED_ESCAPE 249 -> 216.
 */

/* Project destructors that are not part of a declared allocator family: they take ownership of
 * what they are handed and release it. `segment.c`'s `FreeNodes` walks an interval tree and
 * releases every node with `RelinquishMagickMemory` — without the declaration its callers'
 * cleanup paths looked like uncontracted escapes, and the tree they release read as abandoned.
 * All three obligations are declared on the one parameter: the node, and the two children it
 * owns and recurses into. */
// @contract FreeNodes { frees: $1 $1.sibling $1.child }

/* Functions that only READ what they are handed — no ownership crosses the boundary. */
// @contract qsort                   { borrows: $1 }
// @contract GetNextToken            { borrows: $1 $2 $4 }
// @contract CopyMagickString        { borrows: $1 $2 }
// @contract ConcatenateMagickString { borrows: $1 $2 }
// @contract FormatLocaleString      { borrows: $1 $3 }
// @contract LogMagickEvent          { borrows: $4 }
// @contract SetImageProperty        { borrows: $1 $2 $3 $4 }
// @contract GetImageProperty        { borrows: $1 $2 $3 }
// @contract ThrowMagickException    { borrows: $1 $5 $6 }
// @contract read                    { borrows: $2 }

/* The container hand-offs. The collection TAKES the element — its destructor releases it — but
 * putting a pointer in a list does not invalidate the pointer, and MagickCore reads the value
 * back immediately afterwards (`ThrowMagickException(…, color_info->name)` right after the
 * append). `moves:` says the handle is dead and reports those reads as USE_AFTER_MOVE; `frees:`
 * says worse. `adopts:` is the word for exactly this: the release obligation moves to the
 * callee, the object stays valid. The caller may read it and pass it on, must not release it
 * (that is the container's job now), and does not leak it. */
// @contract AppendValueToLinkedList       { adopts: $2 }
// @contract InsertValueInLinkedList       { adopts: $3 }
// @contract InsertValueInSortedLinkedList { adopts: $4 }

/* NOT declared here, deliberately:
 *
 *   - the typed object families (`@allocator magick::kernel { alloc: AcquireKernelInfo,
 *     free_returns_null: DestroyKernelInfo }` and friends). The declaration is true of the API
 *     and clears the escapes at every `Destroy…` call — but `DestroyKernelInfo`'s own body
 *     releases the object with the generic `RelinquishMagickMemory`, which the family
 *     declaration then (correctly) reports as WRONG_DEALLOCATOR: 49 findings, all inside the
 *     destroy functions themselves. Declaring a family whose release is implemented in terms
 *     of another family needs a way to say so; until then the declaration would trade one set
 *     of findings for another.
 * */
