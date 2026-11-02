# Applying kenbi to ImageMagick without touching it

ImageMagick allocates with its own wrappers (`AcquireQuantumMemory`,
`RelinquishMagickMemory`, …). Until those are declared, kenbi has no vocabulary for them and
says nothing about that memory — and a `@mem` at every call site is not an answer for half a
million lines.

The figures in this document were measured in September 2026 on ImageMagick 7.1.2-27
(MagickCore, 95 files) with kenbi as it was then. Later versions of kenbi report different
totals; the commands below reproduce the measurement with the current one.

[`kenbi_magick_mem.h`](kenbi_magick_mem.h) declares the three families once. It contains only
comments, so it can be force-included: **the project's own sources are not edited.**

```sh
IM=/path/to/ImageMagick
kenbi --format=json "$IM/MagickCore/color.c" -- \
  -I "$IM" -I "$IM/MagickCore" -I "$IM/config" \
  -DMAGICKCORE_HDRI_ENABLE=0 -DMAGICKCORE_QUANTUM_DEPTH=16 \
  -include "$(pwd)/demo/imagemagick/kenbi_magick_mem.h"
```

Use the project's OWN compile line. ImageMagick builds with `-fopenmp`, which changes the AST
rather than just the warnings, so add `-fopenmp` and the include path holding `omp.h`
(`-I/usr/lib/gcc/x86_64-linux-gnu/11/include` on Debian/Ubuntu). Three of the 95 MagickCore
files also pull in third-party headers — `-I/usr/include/libxml2 -I/usr/include/freetype2` —
and without them kenbi REFUSES those files (`PARSE_ERROR`) rather than analysing a partial AST,
which is the behaviour you want: a missing include silently drops whole functions.

Declare each family separately: aligned allocations must be released by the aligned function,
so folding them into one family reports a (correct) `WRONG_DEALLOCATOR` on every aligned
release. `free_returns_null` describes the house style `p = Relinquish…(p)`, in which the
release hands the pointer back as NULL.

The typed `Acquire…`/`Destroy…` pairs belong to the generic family too — each destructor frees
the object's fields and then ends `X = RelinquishMagickMemory(X); return X;` — so they are
listed in its `alloc:` / `free_returns_null:` lists, with `frees_fields:` recording that the
destructor releases the object's owned fields. That declaration raises the finding count
(689 → 729 across the 95 files) because a `DestroyKernelInfo(kernel)` call stops being an
uncontracted boundary and becomes a release kenbi checks, which then asks who owns the object.
It is also what surfaced the `OrderedDitherImage` leak below.

Strings belong there as well, and separating them was the overlay's one real mistake:
`DestroyString` is `return (char *) RelinquishMagickMemory(string);` and nothing else, so a
string and a plain buffer are the same block released the same way. While `magick::string` was
its own family the two names were not interchangeable, and MagickCore's own
`token = RelinquishMagickMemory(token)` on an `AcquireString` result — with the mirror,
`DestroyString` on an `AcquireQuantumMemory` buffer — reported `WRONG_DEALLOCATOR`: 12 findings,
every one of them correct C. Merging the family removes all 12 and changes nothing else
(MagickCore 702 → 690, twelve removals and no additions).

Splitting the other way does not work here, and it is worth saying why. Giving each typed
`Destroy…` its own family looks right — those destructors really are not interchangeable with
the generic release — but ImageMagick allocates every one of those objects with the generic
allocator (`kernel = AcquireMagickMemory(sizeof(*kernel))`; `AcquireKernelInfo` parses a kernel
out of a string, it is not where the block comes from). The allocation site states the generic
family, so every `DestroyKernelInfo(kernel)` then reads as a wrong deallocator — 50 of them.
Telling those apart needs a resource identity based on the TYPE rather than on the allocator's
name, which kenbi has no vocabulary for. The cost is recorded rather than hidden: for objects
allocated this way, `WRONG_DEALLOCATOR` cannot catch a mismatch between two of the project's own
destructors.

## The second overlay: the lists

[`kenbi_magick_lists.h`](kenbi_magick_lists.h) declares the intrusive lists MagickCore builds by
hand. Every node of one of those types comes from the same allocator wrapper, so without the
declaration kenbi sees one resource where the program has a chain of objects, and every walk
along the chain reads as a use after free. Add it the same way:

```sh
kenbi "$IM/MagickCore/segment.c" -- … \
  -include "$(pwd)/demo/imagemagick/kenbi_magick_mem.h" \
  -include "$(pwd)/demo/imagemagick/kenbi_magick_lists.h"
```

On segment.c that is 83 findings down to 14 — every `USE_AFTER_FREE` and `DOUBLE_FREE` gone —
for one comment line. Build ImageMagick's own compile line (`-fopenmp` included): kenbi removes
the OpenMP directives before parsing, so a parallel loop's body is analysed like any other.

What a header cannot declare is the drain. `@drains(head)` says that one specific loop releases
every element, and that is a fact about a statement, so those collections stay RED until the
annotation sits at the loop.

## The third overlay: the API contracts

[`kenbi_magick_api.h`](kenbi_magick_api.h) declares what ImageMagick's own functions do with a
pointer they are given. The inline annotations have to sit above a declaration, so they cannot
reach a project that is not being edited; `@contract <Fn> { borrows: $1 }` names the function
instead, and takes parameters by position because these headers declare them unnamed.

```sh
kenbi "$IM/MagickCore/property.c" -- … \
  -include "$(pwd)/demo/imagemagick/kenbi_magick_mem.h" \
  -include "$(pwd)/demo/imagemagick/kenbi_magick_lists.h" \
  -include "$(pwd)/demo/imagemagick/kenbi_magick_api.h"
```

Ten `borrows` declarations: 657 -> 626 findings across the 95 files, `UNCONTRACTED_ESCAPE`
249 -> 216. They also produce two new `LEAK`s, which is the point rather than a regression — a
declared boundary is a decidable one, so a pointer handed to a function that does not take it
and never released afterwards becomes visible.

For a factory, `@allocator` is the better tool: adding `ConvertUTF16ToUTF8` to the
`magick::string` family's `alloc:` list named its resource and its deallocator, which cleared 16
of xml-tree.c's 26 uncontracted releases from the header alone. The file's header comments record
what is deliberately NOT declared yet, and why.

### A second real leak, from the typed-family declaration

`OrderedDitherImage` (MagickCore/threshold.c:1893) acquires a `ThresholdMap` at line 1945 and
returns at line 1972 when `SetImageStorageClass` fails — without the `DestroyThresholdMap(map)`
that every other exit performs. The map and the three heap allocations inside it
(`map_id`, `description`, `levels`) leak on that path, which is reachable whenever the pixel
cache cannot be set to DirectClass.

### A third real leak, on an allocation-failure path

`GetQNodeInfo` (MagickCore/quantize.c:2147) allocates a `QNodes` queue block, then allocates the
node array inside it:

```c
nodes=(QNodes *) AcquireMagickMemory(sizeof(*nodes));
if (nodes == (QNodes *) NULL)
  return((QNodeInfo *) NULL);
nodes->nodes=(QNodeInfo *) AcquireQuantumMemory(QNodesInAList,sizeof(*nodes->nodes));
if (nodes->nodes == (QNodeInfo *) NULL)
  return((QNodeInfo *) NULL);          /* `nodes` is abandoned here */
nodes->next=cube_info->node_queue;     /* ownership only transfers from here on */
cube_info->node_queue=nodes;
```

The second failure path returns before the queue block is linked into `cube_info->node_queue`,
so nothing can reach or release it. Reachable whenever the node-array allocation fails.

### One false LEAK class, found the same way

`NewXMLTreeTag` hands out its heap `XMLTreeRoot` as `return(&root->root)` — the address of the
first member, which is the public `XMLTreeInfo` the caller releases the whole block through.
kenbi read `return &b->member` as returning nothing, so the allocation looked abandoned at the
return: two false `LEAK`s, one for the block and one for the field it owns. Returning the address
of a member of a tracked allocation is now the same transfer `return b` is. MagickCore 716 -> 714,
and xml-tree.c is the only file that changes.

### A second real leak: `EvaluateImages` abandons its row buffer

`EvaluateImages` (MagickCore/statistic.c) has two per-row loops, and both are written this way:

```c
p=(const Quantum **) AcquireQuantumMemory(number_images,sizeof(*p));   /* 592 / 708 */
...
if ((j < (ssize_t) number_images) || (q == (Quantum *) NULL))
  {
    status=MagickFalse;
    continue;                    /* 610 / 726 — `p` is abandoned here */
  }
...
p=(const Quantum **) RelinquishMagickMemory((void *) p);               /* 656 / 798 */
```

The release sits at the end of the iteration, and the early `continue` — taken whenever a source
pixel fetch or the destination queue fails — skips it. The loops are `#pragma omp parallel for`
over image rows, so the leak repeats for every failing row.

### A second false LEAK class: the borrowed tree node

MagickCore walks its colour-cube and xml trees by borrowing a node out of them
(`node_info=cube_info->root`) and allocating into that node
(`node_info->list=AcquireQuantumMemory(...)`). kenbi's field-lifetime rule read the local
`node_info` as a container dying at scope exit, so every such store was a leak — but only the
HANDLE dies; the node belongs to the tree, which outlives the call. The declared type now decides
(an automatic local of pointer type is a handle; a stack struct is the object), and the stack
case is unchanged. MagickCore 714 -> 703, reductions in nine files and increases in none.

### A third false LEAK class: growing an intrusive list

`@list Cluster { link: next }` tells kenbi that `Cluster` objects form a chain whose origin
stands for the whole collection. MagickCore grows that chain the way C always does —
`cluster->next=AcquireQuantumMemory(...); cluster=cluster->next;` — and the assignment read as a
field the local `cluster` owned, so each list-building loop leaked once per node on top of the
collection's own obligation. An assignment to the declared link field is the next element of the
collection the base is already in. MagickCore 703 -> 700.

What remains in segment.c and the other list builders is the collection origin itself: its
release loop carries no `@drains`, and kenbi does not edit ImageMagick. That is the declared-drain
discipline working as intended — a chain nobody declares drained stays RED.

### A third real leak: `GetQCubeInfo` abandons the cube on its failure paths

`GetQCubeInfo` (MagickCore/quantize.c:2073) is the factory whose companion `GetQNodeInfo` leaks
its queue block (above). It leaks too, twice:

```c
cube_info=(QCubeInfo *) AcquireMagickMemory(sizeof(*cube_info));
if (cube_info == (QCubeInfo *) NULL)
  return((QCubeInfo *) NULL);
...
cube_info->root=GetQNodeInfo(cube_info,0,0,(QNodeInfo *) NULL);
if (cube_info->root == (QNodeInfo *) NULL)
  return((QCubeInfo *) NULL);          /* `cube_info` is abandoned */
...
cube_info->memory_info=AcquireVirtualMemory(length,sizeof(*cube_info->cache));
if (cube_info->memory_info == (MemoryInfo *) NULL)
  return((QCubeInfo *) NULL);          /* `cube_info` AND the node queue it now owns */
```

Neither failure path releases the cube it has already built. The second also abandons everything
`GetQNodeInfo` allocated into `cube_info->node_queue`. Both are the same allocation-failure
shape as the other two leaks in this file and in statistic.c.

### A fourth false LEAK class, found by delta-debugging

`GetImageStatistics` (statistic.c) allocates `channel_statistics`, takes interior aliases into it
(`cs=channel_statistics+(ssize_t) channel`), conditionally releases it with the NULL-returning
`RelinquishMagickMemory`, and returns it. kenbi reported a leak at the allocation and a dangling
return — both wrong. Isolating it meant blanking balanced line ranges of the 360-line function
(rejecting any cut that failed to compile) until the finding disappeared, which pinned a single
line: the interior alias.

The alias must keep the freed origin alive so a use through it after the release is still caught,
which leaves the join holding the origin owned and freed at once. kenbi now records which handle
a NULL-returning release nulled, so returning that handle is understood as returning NULL on that
path while the other path transfers the block out. MagickCore 700 -> 698.

### A fifth class, and a detection gap behind it

`SetXMLTreeAttribute` grows its attribute table in place with
`xml_info->attributes=ResizeQuantumMemory(xml_info->attributes,…)`. kenbi lowered that as a FRESH
allocation into a field that already owned something and called it a leak of the table it was
growing — because the field path recognised only the builtin `realloc` by name, not the family
the overlay declares (`@allocator … { realloc: ResizeQuantumMemory }`). The plain-variable path
had always got this right.

Fixing it removed the whole field-overwrite group (xml-tree.c 1570 / 2440, draw.c 559) and made
six previously-invisible field grow-in-place sites report the `REALLOC_SELF_REASSIGN` their
plain-variable twins always did. MagickCore 698 -> 700: one false-positive class out, one
detection gap closed, and the total goes up because the second outnumbers the first.

### Publishing the overlay as a contract set

The three headers are also a *distributable* artifact — the thing a library would ship (or a
consumer would write for a library that has not adopted kenbi). `--emit-contracts` prints them in
machine-readable form, together with what this run established about each contract:

```sh
kenbi --emit-contracts "$IM"/MagickCore/*.c -- … > imagemagick.contracts.json
```

Over all 95 MagickCore files, the result is the honest one: the package resolves to ImageMagick
7.1.2-27 with `appliesToThisBuild: true` (its `requires:` match this compile line), three resource
families carry their alloc → free vocabulary, and all 22 function contracts come back
**`unchecked`** or **`declared`** — ImageMagick's implementations are present but no `@kenbi`
marker adopts them, so not one of these contracts has been verified against its implementation.
A consumer reading the file cannot mistake the overlay for a verification of ImageMagick.

## The container hand-offs, and what declaring them found

MagickCore's configuration parsers all have the same shape: a `<x …` token allocates the
element, later tokens fill its fields, and a `/>` token hands it to a linked list.

```c
if (LocaleCompare(keyword,"<color") == 0)
  {
    color_info=(ColorInfo *) AcquireCriticalMemory(sizeof(*color_info));
    (void) memset(color_info,0,sizeof(*color_info));
    color_info->path=ConstantString(filename);
    …
    continue;
  }
…
if ((LocaleCompare(keyword,"/>") == 0) || …)
  {
    status=AppendValueToLinkedList(cache,color_info);
    if (status == MagickFalse)
      (void) ThrowMagickException(…,"`%s'",color_info->name);   /* read AFTER the append */
    color_info=(ColorInfo *) NULL;
    continue;
  }
```

`AppendValueToLinkedList` was left undeclared here, with a note that declaring it as
`{ moves: $2 }` produced nine untriaged `USE_AFTER_MOVE`. Triaged: the contract was the wrong
word. The list takes the *release obligation*, not the pointer's validity — the line right after
the append reads `color_info->name`, which is ordinary C. `@moves` declares the handle dead;
`@frees` declares it released. Neither is true, so kenbi gained the word that is:
`adopts:` — the obligation moves to the callee, the object stays valid. All nine
`USE_AFTER_MOVE` are gone, and seven `UNCONTRACTED_ESCAPE` boundaries became decided.

What the declaration then surfaces is a real leak, in every one of those parsers. `color_info`
is only handed to the list when the `/>` token arrives; if the configuration file ends first —
a truncated or malformed element — the loop exits with the element still held, and the function
ends `token=RelinquishMagickMemory(token); return(…)` with no cleanup of it. The element and the
strings it has already been given leak. kenbi reports the element (it always did) and now also
the fields, which are only visible once the hand-off accounts for the ones that do get appended:

| file | element | fields also leaked |
|---|---|---|
| `color.c` 2095 | `color_info` | `->path` 2097, `->name` 2153 |
| `configure.c` 1262 | `configure_info` | `->path` 1265, `->name` 1298, `->value` 1318 |
| `delegate.c` 2170 | `delegate_info` | `->path` 2173, and three more at 2206 / 2236 / 2247 |
| `log.c` 1013 | `log_info` | `->path` 1015, `->filename` 1057, `->format` 1065 |
| `locale.c`, `policy.c`, `property.c`, `type.c` | same shape | element only |

MagickCore 690 → 695: seven undecided boundaries resolved, twelve more true leak reports.

## A leak on one error path in `GetImageFeatures`

`feature.c` allocates six buffers together and releases all six in the allocation-failure ladder
at 790–805. The SECOND error exit does not:

```c
  if (status == MagickFalse)
    {
      for (i=0; i < (ssize_t) number_grays; i++)
        cooccurrence[i]=(ChannelStatistics *) RelinquishMagickMemory(cooccurrence[i]);
      cooccurrence=(ChannelStatistics **) RelinquishMagickMemory(cooccurrence);
      channel_features=(ChannelFeatures *) RelinquishMagickMemory(channel_features);
      (void) ThrowMagickException(…);
      return(channel_features);                      /* feature.c:991 */
    }
```

`density_x` (777), `density_xy` (779), `density_y` (781), `Q` (783) and `sum` (784) are still
held, and the `Q[i]` rows allocated in the loop go with them. The earlier exit at 859 releases
all of them; this one releases two. kenbi reports exactly those five.

## Auditing every LEAK finding

`LEAK` is the accusation class — the one where a finding claims the code is wrong — so it is the
one worth reading one by one. All 49 on MagickCore were, by opening each site and checking every
exit reachable after the allocation. The tool for it is `demo/imagemagick/audit.py`: it prints
the enclosing function with every mention of the variable and every `return`, which is all the
evidence the judgement needs.

**34 are real.** Two shapes:

*One error exit skips the cleanup the others do* (16):

| site | what happens |
|---|---|
| `effect.c` 3460 | the `return NULL` at 3517 skips the `RelinquishAlignedMemory(kernel)` that 3521 / 3528 / 3536 all do |
| `feature.c` 777, 779, 781, 783, 784 | six buffers are allocated together; the exit at 991 releases two of them |
| `histogram.c` 515 | `AcquireHCubeInfo` returns NULL when `GetHNodeInfo` fails, abandoning the cube it just allocated |
| `distort.c` 497 | two error returns skip `RelinquishMagickMemory(coeff)`; the other two do it |
| `pixel.c` 4191 | an error return skips `quantum_map` |
| `compress.c` 1253 | the deflate-failure `ThrowBinaryException` skips `compress_pixels` |
| `quantize.c` 2073, 2160, 2163 · `statistic.c` 592, 708 · `threshold.c` 1945 | reported in earlier rounds |

*The configuration parsers leak a truncated element* (18, across `color.c`, `configure.c`,
`delegate.c`, `log.c`, `policy.c`, `type.c`). The element is allocated on `<x` and handed to the
list on `/>`; if the file ends between the two, the loop exits still holding it and the function
returns with no cleanup. Described in full in the section above.

**8 are false, and each has a named cause:**

| site | cause |
|---|---|
| `segment.c` 517 | the cleanup lives inside the `ThrowClassifyException` macro, behind a null guard, and restores an interior pointer (`squares -= 255`) first |
| `fx.c` 4222, 4284 | every path that releases `pfx` destroys the field first, and the path that does not has nothing to free (the allocation failed) |
| `memory.c` 738 | the overwrite happens only on the branch where the field is already NULL — fixed, see below |
| `linked-list.c` 590 | the element is linked into the intrusive list it belongs to |

`draw.c` 628 and 687 were carried in an earlier note as loop-carried-ownership false positives.
Reading them settles it the other way: `ConvertPathToPolygon` stores each point buffer into the
edge array, but the `polygon_info->edges` resize at 735 fails into
`return(DestroyPolygonInfo(polygon_info))` at 741 while `points` is live and not yet stored — so
that OOM path does abandon it. They are **true**. (The sibling return at 714 is after
`points = ResizeQuantumMemory(points, …)` has already overwritten the only handle, which kenbi
reports at 708 as `REALLOC_SELF_REASSIGN` — the leak is real there too, one line earlier.)

**8 are not individually settled** (`annotate.c` 1644, `property.c` 1582, `morphology.c` 1029,
`segment.c` 331 / 1032 / 1407, `draw.c` 3741, `xml-tree.c` 2708) — large functions or the known
out-parameter-resize vocabulary gap.

So the LEAK class on this codebase is **at least 73% true (36/49)** and at most 27% false. That
is the first false-positive rate kenbi has measured on real code rather than on a synthetic
corpus, and it is measured on the one class where being wrong costs the most. After the
`memory.c` fix below, 47 remain and 4 of them are known false.

### Loop-carried ownership: measured, and not shipped

The remaining question was whether an allocation made in one iteration and consumed in the next
is accounted for. It is not: the loop fixpoint carries the ownership STATE across the back edge
but restores the variable→origin BINDINGS from the entry on every pass, so the handle is unbound
at the head and the store that consumes it sees nothing.

Carrying the bindings too — joining the body's exit bindings into the head exactly as at any
other join — was implemented and measured. It works, and it must not ship as it stands:
MagickCore 690 → 677, and **19 of the 13 removed findings are ones this audit confirmed as
real**. The configuration parsers are the reason. Once the hand-off from a previous iteration is
visible, the element's origin carries `asEscaped` from the path that appended it, and the leak
scan treats a MAY-escape as a blanket suppressor — so the element that is never appended goes
silent. Making that suppressor a must-fact (`st[o] == {asEscaped}`) restores them and adds 40
other findings across the codebase, none of them audited: 717 total.

So the two are coupled, and the pair needs a round of its own with those 40 read one by one.
Reverted rather than shipped, and recorded here rather than left as a number that moved.

### What `memory.c:738` exposed

```c
b->blob = AcquireAlignedMemory(1,size);
…
if (b->blob == NULL)          /* only reached when the field IS null */
  b->blob = MapBlob(…);       /* LEAK: "still owns … when it is overwritten here" */
```

The overwrite is guarded by the field being NULL, so nothing is lost. kenbi narrows a null guard
for a plain variable and not for a one-level field path, and the asymmetry is visible in two
lines:

```c
if (p == NULL)       p       = malloc(32);   /* clean */
if (b->blob == NULL) b->blob = malloc(32);   /* false LEAK */
```

Fixed by teaching the guard recogniser the one-level field path — the engine already tracks
`b->blob` under the same kind of key, so every narrowing downstream worked unchanged. MagickCore
695 → 690: `memory.c` 738 and `quantize.c` 2163 go, and three `UNCONTRACTED_ESCAPE` in `cache.c`
and `string.c` with them (a field the branch proves NULL carries no obligation across a call).
`quantize.c` 2160 — the real leak of the *container* on that same error path — stays, which is
the point: the field report was the wrong half of it.
