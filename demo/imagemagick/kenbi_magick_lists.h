/* kenbi overlay for ImageMagick — the intrusive lists MagickCore builds by hand.
 *
 * This file contains ONLY comments, so it can be force-included with `-include`:
 * ImageMagick's own sources are not edited.
 *
 * Every node of one of these types comes from the same allocator wrapper, so kenbi sees one
 * resource where the program has a chain of objects. Declaring the link field says so: a walk
 * (`p = p->next`) is then another element of the same collection rather than a pointer kenbi
 * cannot place, a release in the walk is an ELEMENT removal rather than a release of "the"
 * resource, and reading the link out of an element that was just released is the use-after-free
 * it is. On segment.c alone this turns 83 findings into 14 — the cluster list is walked in nine
 * functions, and every walk read as a use after free.
 *
 * What a header CANNOT declare is the drain: `@drains(head)` says that one specific loop
 * releases every element, which is a fact about a statement. Until it sits at the loop, a
 * collection nothing visibly drains stays RED — the question kenbi should ask, not one it can
 * answer from outside the file.
 */

// @list Cluster     { link: next }   /* segment.c   — the fuzzy c-means cluster list */
// @list ElementInfo { link: next }   /* linked-list.c — the generic list's elements */
// @list HNodes      { link: next }   /* histogram.c — the colour-cube node arena list */
