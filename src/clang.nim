## Minimal libclang FFI binding.
##
## Only the slice of the stable C API (`clang-c/Index.h`) that the front-end
## needs: parse a translation unit, walk cursors, read spellings / locations,
## and tokenize for comment annotations. The by-value structs (CXCursor,
## CXString, CXSourceLocation, CXToken) are laid out to match the C ABI exactly
## — see the struct comments. Verified against libclang-14.
##
## Loaded dynamically so the binary needs no link-time libclang; override the
## library name via `-d:kenbiLibclang=...` if your soname differs.

import std/os

const libclang {.strdefine: "kenbiLibclang".} =
  "(libclang.so|libclang.so.1|libclang-18.so|libclang-17.so|libclang-16.so|" &
  "libclang-15.so|libclang-14.so|libclang-14.so.1|libclang-13.so)"

type
  CXTargetInfo* = pointer
  CXIndex* = pointer
  CXTranslationUnit* = pointer
  CXFile* = pointer
  CXClientData* = pointer
  CXEvalResult* = pointer   ## opaque handle from clang_Cursor_Evaluate

  ## { const void* data; unsigned private_flags; }
  CXString* {.bycopy.} = object
    data: pointer
    private_flags: cuint

  ## { enum CXCursorKind kind; int xdata; const void* data[3]; }
  CXCursor* {.bycopy.} = object
    kind*: cint
    xdata: cint
    data: array[3, pointer]

  ## { const void* ptr_data[2]; unsigned int_data; }
  CXSourceLocation* {.bycopy.} = object
    ptr_data: array[2, pointer]
    int_data: cuint

  ## { const void* ptr_data[2]; unsigned begin_int_data; unsigned end_int_data; }
  CXSourceRange* {.bycopy.} = object
    ptr_data: array[2, pointer]
    begin_int_data: cuint
    end_int_data: cuint

  ## { unsigned int_data[4]; void* ptr_data; }
  CXToken* {.bycopy.} = object
    int_data: array[4, cuint]
    ptr_data: pointer

  ## { enum CXTypeKind kind; void* data[2]; }
  CXType* {.bycopy.} = object
    kind*: cint
    data: array[2, pointer]

  ## { const char *Filename; const char *Contents; unsigned long Length; }
  ## An in-memory replacement for a file on disk, handed to clang_parseTranslationUnit.
  CXUnsavedFile* {.bycopy.} = object
    filename*: cstring
    contents*: cstring
    length*: culong

  CXChildVisitResult* = enum
    cvrBreak = 0, cvrContinue = 1, cvrRecurse = 2

  CXCursorVisitor* = proc (cursor, parent: CXCursor, client: CXClientData): CXChildVisitResult {.cdecl.}
  CXInclusionVisitor* = proc (included: CXFile, stack: ptr CXSourceLocation,
                              stackLen: cuint, client: CXClientData) {.cdecl.}

const CXEval_Int* = 1.cint  ## CXEvalResultKind: the expression evaluated to an integer

# --- Cursor kinds we care about (CXCursorKind values are ABI-stable) ---
const
  ckFieldDecl*      = 6
  ckFunctionDecl*   = 8
  # --- function-like definitions and the containers that nest them. Every one of these can
  # hold a body with dangerous operations; a collector that only looks at top-level
  # ckFunctionDecl silently DROPS them (a false GREEN by omission — the crown-jewel failure).
  ckUnexposedDecl*  = 1    ## libclang's catch-all for declarations it does not expose — and,
                          ## in practice, how an `extern "C" { ... }` block comes back (NOT as
                          ## ckLinkageSpec, which exists in the enum but is not what the
                          ## block cursor reports). Verified by dumping the TU: `<cstdlib>`'s
                          ## extern "C" region is `kind=1` with the C decls as its children.
  ckStructDecl*     = 2
  ckUnionDecl*      = 3
  ckClassDecl*      = 4
  ckCXXMethod*      = 21   ## a member function (definition inline in the class, or out-of-line)
  ckNamespace*      = 22   ## `namespace X { ... }` — functions inside are its children
  ckLinkageSpec*    = 23   ## `extern "C" { ... }` — functions inside are its children
  ckConstructor*    = 24
  ckDestructor*     = 25
  ckConversionFunction* = 26
  ckFunctionTemplate* = 30 ## a function template: its (uninstantiated) body is still an AST
  ckClassTemplate*  = 31
  ckVarDecl*        = 9
  ckParmDecl*       = 10
  ckCXXBaseSpecifier* = 44  ## `: public Base` in a class definition — references the base
  ckTypeRef*        = 43   ## a reference to a type in a decl (e.g. the `T` of `T *v;`) — not
                          ## an initializer expression, so its presence ≠ the var has an init
  ckCallExpr*       = 103
  ckDeclRefExpr*    = 101
  ckMemberRefExpr*  = 102
  ckBinaryOperator* = 114
  ckCompoundAssign* = 115
  ckUnaryOperator*  = 112
  ckIfStmt*         = 205
  ckSwitchStmt*     = 206
  ckCaseStmt*       = 203
  ckDefaultStmt*    = 204
  ckWhileStmt*      = 207
  ckDoStmt*         = 208
  ckForStmt*        = 209
  ckCompoundStmt*   = 202
  ckLabelStmt*      = 201
  ckGotoStmt*       = 210
  ckIndirectGotoStmt* = 211
  ckContinueStmt*   = 212
  ckBreakStmt*      = 213
  ckReturnStmt*     = 214
  ckDeclStmt*       = 231
  ckParenExpr*           = 111
  ckUnexposedExpr*       = 100
  ckIntegerLiteral*      = 106
  ckArraySubscriptExpr*  = 113
  ckCStyleCastExpr*      = 117
  ckCXXNewExpr*          = 134
  ckCXXThisExpr*         = 132   ## the `this` base of a member access inside a member function
  ckCXXThrowExpr*        = 133   ## `throw e;` / `throw;` — control leaves the function (unwinding)
  ckCXXCatchStmt*        = 223
  ckCXXTryStmt*          = 224
  ckLambdaExpr*          = 144   ## `[capture](params){ body }` — its child is the body
  ckCXXForRangeStmt*     = 225   ## `for (T x : range) { ... }` — children: the loop variable
                                 ## decl, the range expression, the body
  ckCXXDeleteExpr*       = 135

# --- Type kinds (CXTypeKind, ABI-stable) — the array kinds decay to a pointer
#     into their storage, so returning a local one of these escapes the stack ---
const
  tyRecord*              = 105
  tyEnum*                = 106
  tyPointer*             = 101
  tyConstantArray*       = 112
  tyIncompleteArray*     = 114
  tyVariableArray*       = 115
  tyDependentSizedArray* = 116

# --- Storage classes (CX_StorageClass, ABI-stable). A local with static/extern
#     storage outlives the call, so its address does NOT dangle on return. ---
const
  scStatic* = 3
  scExtern* = 2

# --- Token kinds ---
const
  tkPunctuation* = 0
  tkKeyword*     = 1
  tkIdentifier*  = 2
  tkLiteral*     = 3
  tkComment*     = 4

{.push cdecl, dynlib: libclang, importc.}

proc clang_createIndex*(excludeDeclarationsFromPCH, displayDiagnostics: cint): CXIndex
proc clang_disposeIndex*(index: CXIndex)
proc clang_parseTranslationUnit*(index: CXIndex, sourceFilename: cstring,
  cmdLineArgs: cstringArray, numArgs: cint, unsavedFiles: pointer,
  numUnsaved: cuint, options: cuint): CXTranslationUnit
proc clang_disposeTranslationUnit*(tu: CXTranslationUnit)
proc clang_getTranslationUnitTargetInfo*(tu: CXTranslationUnit): CXTargetInfo
proc clang_TargetInfo_dispose*(info: CXTargetInfo)
proc clang_TargetInfo_getTriple*(info: CXTargetInfo): CXString
proc clang_TargetInfo_getPointerWidth*(info: CXTargetInfo): cint
proc clang_getTranslationUnitCursor*(tu: CXTranslationUnit): CXCursor
# --- parse diagnostics. A translation unit with error-severity diagnostics (a missing include,
# a type error) still comes back non-nil as a PARTIAL AST — functions that depend on the
# missing pieces simply do not lower. Without reading these, such a parse looks like a clean
# file with nothing to check (exit 0): a false pass at the gate. Severity: 0 Ignored, 1 Note,
# 2 Warning, 3 Error, 4 Fatal.
proc clang_getNumDiagnostics*(tu: CXTranslationUnit): cuint
proc clang_getDiagnostic*(tu: CXTranslationUnit, index: cuint): pointer
proc clang_getDiagnosticSeverity*(diag: pointer): cint
proc clang_getDiagnosticSpelling*(diag: pointer): CXString
proc clang_disposeDiagnostic*(diag: pointer)
proc clang_visitChildren*(parent: CXCursor, visitor: CXCursorVisitor, client: CXClientData): cuint

proc clang_Cursor_getVarDeclInitializer*(c: CXCursor): CXCursor
proc clang_Cursor_getNumArguments*(c: CXCursor): cint
proc clang_Cursor_getArgument*(c: CXCursor, index: cuint): CXCursor
proc clang_getCursorKind*(c: CXCursor): cint
proc clang_getCursorLinkage*(c: CXCursor): cint
proc clang_getClangVersion*(): CXString
proc clang_getCursorSpelling*(c: CXCursor): CXString
proc clang_getCursorReferenced*(c: CXCursor): CXCursor
proc clang_getCursorType*(c: CXCursor): CXType
proc clang_getResultType*(t: CXType): CXType
proc clang_getCanonicalType*(t: CXType): CXType
proc clang_equalTypes*(a, b: CXType): cuint
proc clang_getCursorSemanticParent*(c: CXCursor): CXCursor  ## the class a member function belongs
                                                            ## to (also for an out-of-line def)
proc clang_getCursorExceptionSpecificationType*(c: CXCursor): cint
  ## The exception specification of a function DECL cursor (CXCursor_ExceptionSpecificationKind):
  ## -1 not a function · 0 None (may throw) · 1 DynamicNone `throw()` · 2 Dynamic `throw(T)` ·
  ## 3 MSAny · 4 BasicNoexcept `noexcept` · 5 ComputedNoexcept `noexcept(expr)` ·
  ## 6 Unevaluated · 7 Uninstantiated · 8 Unparsed · 9 NoThrow (`__attribute__((nothrow))`).
proc clang_getTypeSpelling*(t: CXType): CXString   ## `kir_owned_scalar<std::uint32_t>` etc. — used
                                                    ## to match a local's type against `@raii` owners
proc clang_isConstQualifiedType*(t: CXType): cuint
proc clang_getTypeDeclaration*(t: CXType): CXCursor
proc clang_getCursorDefinition*(c: CXCursor): CXCursor
proc clang_CXXMethod_isVirtual*(c: CXCursor): cuint
proc clang_getPointeeType*(t: CXType): CXType
proc clang_getArrayElementType*(t: CXType): CXType
proc clang_Type_getAlignOf*(t: CXType): clonglong
proc clang_Type_getSizeOf*(t: CXType): clonglong
proc clang_getArraySize*(t: CXType): clonglong
proc clang_Cursor_getStorageClass*(c: CXCursor): cint
proc clang_getCursorUSR*(c: CXCursor): CXString
proc clang_getCursorExtent*(c: CXCursor): CXSourceRange
proc clang_getCursorLocation*(c: CXCursor): CXSourceLocation
proc clang_CXXConstructor_isCopyConstructor*(c: CXCursor): cuint
  ## Is this constructor the class's COPY constructor (`X(const X&)` / `X(X&)`)?
proc clang_CXXMethod_isDefaulted*(c: CXCursor): cuint
  ## Is this member declared `= default`? A defaulted copy on a class that owns a raw pointer
  ## is the shallow copy, so it counts as NOT having written one. (`clang_CXXMethod_isDeleted`
  ## would be the companion, but it does not exist before libclang 16 — `= delete` is detected
  ## from the declaration's tokens instead, which works on every supported version.)
proc clang_Cursor_isNull*(c: CXCursor): cint
proc clang_getNullCursor*(): CXCursor
proc clang_getCursorLanguage*(c: CXCursor): cint  ## CXLanguageKind: 1 C, 2 ObjC, 3 C++
proc clang_equalCursors*(a, b: CXCursor): cuint
proc clang_Location_isFromMainFile*(loc: CXSourceLocation): cint

proc clang_getRangeStart*(r: CXSourceRange): CXSourceLocation
proc clang_getRangeEnd*(r: CXSourceRange): CXSourceLocation
proc clang_equalLocations*(a, b: CXSourceLocation): cuint
proc clang_getExpansionLocation*(loc: CXSourceLocation, file: ptr CXFile,
  line, column, offset: ptr cuint)
proc clang_getSpellingLocation*(loc: CXSourceLocation, file: ptr CXFile,
  line, column, offset: ptr cuint)

proc clang_tokenize*(tu: CXTranslationUnit, r: CXSourceRange,
  tokens: ptr ptr CXToken, numTokens: ptr cuint)
proc clang_getTokenKind*(t: CXToken): cint
proc clang_getTokenSpelling*(tu: CXTranslationUnit, t: CXToken): CXString
proc clang_getTokenLocation*(tu: CXTranslationUnit, t: CXToken): CXSourceLocation
proc clang_getTokenExtent*(tu: CXTranslationUnit, t: CXToken): CXSourceRange
proc clang_disposeTokens*(tu: CXTranslationUnit, tokens: ptr CXToken, n: cuint)

proc clang_getFileName*(file: CXFile): CXString
proc clang_getFile*(tu: CXTranslationUnit, filename: cstring): CXFile
proc clang_getInclusions*(tu: CXTranslationUnit, visitor: CXInclusionVisitor,
                          client: CXClientData)
  ## Every file the translation unit includes, with its inclusion stack. Needed because a
  ## file that DECLARES nothing (a project's annotation overlay, force-included with
  ## `-include`) has no cursor located in it, so walking cursors never finds it — and its
  ## declarations would be silently ignored.
proc clang_getFileContents*(tu: CXTranslationUnit, file: CXFile, size: ptr csize_t): cstring
proc clang_getLocationForOffset*(tu: CXTranslationUnit, file: CXFile, offset: cuint): CXSourceLocation
proc clang_getRange*(rangeBegin, rangeEnd: CXSourceLocation): CXSourceRange
proc clang_Location_isInSystemHeader*(loc: CXSourceLocation): cint
proc clang_getCString*(s: CXString): cstring
proc clang_disposeString*(s: CXString)

# Compile-time constant evaluation (CXEvalResult is an opaque handle). Used to
# fold constant branch conditions (`if(1)` / `if(5==5)` / a const flag) so the
# dead branch is not analysed as a live path.
proc clang_Cursor_Evaluate*(c: CXCursor): CXEvalResult
proc clang_EvalResult_getKind*(e: CXEvalResult): cint
proc clang_EvalResult_getAsLongLong*(e: CXEvalResult): clonglong
proc clang_EvalResult_isUnsignedInt*(e: CXEvalResult): cuint
proc clang_EvalResult_getAsUnsigned*(e: CXEvalResult): culonglong
proc clang_EvalResult_dispose*(e: CXEvalResult)
proc clang_Cursor_getOffsetOfField*(c: CXCursor): clonglong  ## bits; negative when not a field
proc clang_Cursor_isBitField*(c: CXCursor): cuint

{.pop.}

# --- Ergonomic Nim wrappers -------------------------------------------------

proc `$`*(s: CXString): string =
  ## Copy a CXString into a Nim string and dispose the libclang buffer.
  let c = clang_getCString(s)
  result = if c.isNil: "" else: $c
  clang_disposeString(s)

proc spelling*(c: CXCursor): string =
  $clang_getCursorSpelling(c)

import std/tables

var keyAlias*: Table[string, string]
  ## decl USR -> the USR it stands for: a C++ REFERENCE local bound to a variable
  ## (`char *&dataRef = data;`) IS that variable for its whole lifetime (never reseated), so
  ## every reference to it resolves to the referred variable's identity. Reset per parse.

proc usr*(c: CXCursor): string =
  ## Unified Symbol Resolution: a stable, declaration-unique identifier. Unlike
  ## the spelling, it distinguishes shadowed / same-named decls in different
  ## scopes (it embeds the decl's location). Verified non-empty for locals on
  ## libclang-14.
  $clang_getCursorUSR(c)

proc referencedUsr*(c: CXCursor): string =
  ## USR of the declaration a reference (e.g. DeclRefExpr) resolves to — through a C++
  ## reference alias (keyAlias) to the variable it stands for.
  let u = usr(clang_getCursorReferenced(c))
  keyAlias.getOrDefault(u, u)

proc isArrayType*(c: CXCursor): bool =
  ## True if the cursor's type is an array (decays to a pointer into its own
  ## storage), so naming a local array as an rvalue yields a stack pointer.
  clang_getCursorType(c).kind in [tyConstantArray, tyIncompleteArray,
                                  tyVariableArray, tyDependentSizedArray]

proc isPointerType*(c: CXCursor): bool =
  ## True if the cursor's declared type is a raw pointer (`T *`). Used to seed an
  ## undeclared pointer parameter as an incoming-pointer origin (intake discipline).
  ## Arrays decay to pointers but are spatial, not ownership intake — excluded here.
  clang_getCursorType(c).kind == tyPointer

proc isIntegerType*(c: CXCursor): bool =
  ## True if the cursor's type is an integer (after resolving typedefs like size_t /
  ## uint32_t via the canonical type). CXTypeKind Bool..Int128 are 3..20; Enum is 106.
  ## Used by the SPATIAL axis to lower scalar-integer dataflow (index / size values) —
  ## pointers, floats and aggregates are excluded.
  let k = clang_getCanonicalType(clang_getCursorType(c)).kind
  (k >= 3 and k <= 20) or k == 106

proc isUnsignedInteger*(c: CXCursor): bool =
  ## True if the cursor's canonical type is an UNSIGNED integer (Bool .. UInt128 are
  ## CXTypeKind 3 .. 12; the signed kinds Char_S .. Int128 are 13 .. 20). Used by the
  ## INVARIANT init/establish check: an unsigned size operand is known `>= 0`, so a
  ## `field = 0` write establishes `field <= size` (`0 <= size`). A SIGNED size cannot
  ## be assumed non-negative, so the same write is NOT establishable (default-red).
  let k = clang_getCanonicalType(clang_getCursorType(c)).kind
  k >= 3 and k <= 12

proc fixedArraySize*(c: CXCursor): int =
  ## The element count of a fixed-size array (`T buf[N]` -> N), via the canonical type
  ## so a typedef'd array resolves. Returns -1 if `c` is not a constant-size array.
  ## The SPATIAL axis uses this to check a bound is APPROPRIATE — that it actually
  ## covers the buffer being accessed, not merely that some check is present.
  let t = clang_getCanonicalType(clang_getCursorType(c))
  if t.kind != tyConstantArray: return -1
  int(clang_getArraySize(t))

proc hasAutomaticStorage*(c: CXCursor): bool =
  ## True for ordinary stack locals; false for `static` / `extern` ones whose
  ## storage outlives the call (their address is safe to return).
  clang_Cursor_getStorageClass(c) notin [scStatic, scExtern]

proc isNull*(c: CXCursor): bool =
  clang_Cursor_isNull(c) != 0

proc constIntValue*(c: CXCursor): tuple[known: bool, value: int64] =
  ## Evaluate `c` as a compile-time integer constant (`1`, `5==5`, a `const`/
  ## `#define` flag, `sizeof`…). Returns known=false for any non-constant
  ## expression (a parameter, a runtime pointer test, a function call), so a
  ## genuine runtime branch is never folded away.
  let e = clang_Cursor_Evaluate(c)
  if e.isNil: return (false, 0'i64)
  defer: clang_EvalResult_dispose(e)
  if clang_EvalResult_getKind(e) == CXEval_Int:
    return (true, int64(clang_EvalResult_getAsLongLong(e)))
  (false, 0'i64)

proc lineOf*(loc: CXSourceLocation): int =
  var line, col, off: cuint
  clang_getSpellingLocation(loc, nil, addr line, addr col, addr off)
  int(line)

var workingDirectory*: string
  ## The `-working-directory` the translation unit being analysed was parsed with ("" when
  ## none). libclang 17 and later name a file reached through a relative include path
  ## relative to it, where libclang 14 named it absolutely.

proc fileName*(f: CXFile): string =
  ## The path of a file in the translation unit, the same with every libclang: a name libclang
  ## gives relative to the working directory it parsed with is resolved against that directory,
  ## not against kenbi's own.
  if f.isNil: return ""
  result = $clang_getFileName(f)
  if result.len > 0 and workingDirectory.len > 0 and not result.isAbsolute:
    result = workingDirectory / result

proc fileOf*(loc: CXSourceLocation): string =
  ## The file path a location belongs to (so cross-file contract binding doesn't
  ## confuse same line numbers in different files).
  var f: CXFile
  clang_getSpellingLocation(loc, addr f, nil, nil, nil)
  fileName(f)

proc startLine*(c: CXCursor): int =
  ## The first line of the cursor's extent. libclang-14 gives some expressions no valid extent
  ## at all (an assignment from `new struct S`); the cursor's own location stands in for it.
  result = lineOf(clang_getRangeStart(clang_getCursorExtent(c)))
  if result == 0: result = lineOf(clang_getCursorLocation(c))

proc endLine*(c: CXCursor): int =
  lineOf(clang_getRangeEnd(clang_getCursorExtent(c)))

proc offsetOf*(loc: CXSourceLocation): int =
  var line, col, off: cuint
  clang_getSpellingLocation(loc, nil, addr line, addr col, addr off)
  int(off)

proc startOffset*(c: CXCursor): int =
  offsetOf(clang_getRangeStart(clang_getCursorExtent(c)))

proc endOffset*(c: CXCursor): int =
  offsetOf(clang_getRangeEnd(clang_getCursorExtent(c)))
