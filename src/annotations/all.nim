## Register every built-in annotation plugin. To add an annotation: create
## `annotations/ann_<x>.nim` with a `register<X>*` proc, then import it here and
## call it in `registerBuiltinAnnotations`. Nothing else in the codebase changes.

import advisory
import nullsafety
import ownership

proc registerBuiltinAnnotations* =
  registerAdvisory()
  registerNullSafety()
  registerOwnership()
