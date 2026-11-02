## Ordered, deliberately explicit C subset for configured protocol checks.
## No third-party implementation or device specification is embedded here.
import std/[json, os, strutils]
import clang, cfront_core

proc protocolSymbol*(c: CXCursor): string =
  result = usr(c)
  if result.len > 0 and clang_getCursorLinkage(c) == 2:
    result = absolutePath(fileOf(clang_getCursorLocation(c))) & "#" & result

proc rangeTokens(tu: CXTranslationUnit, extent: CXSourceRange,
                 first = low(int), last = high(int)): seq[string] =
  var data: ptr CXToken
  var count: cuint
  clang_tokenize(tu, extent, addr data, addr count)
  defer: clang_disposeTokens(tu, data, count)
  let items = cast[ptr UncheckedArray[CXToken]](data)
  for i in 0 ..< int(count):
    let offset = offsetOf(clang_getTokenLocation(tu, items[i]))
    if offset >= first and offset < last and clang_getTokenKind(items[i]) != tkComment:
      result.add $clang_getTokenSpelling(tu, items[i])

proc tokens(tu: CXTranslationUnit, c: CXCursor): seq[string] =
  rangeTokens(tu, clang_getCursorExtent(c))

proc alignmentLiteral(number: string): BiggestInt =
  ## Parse only C integer-token spelling, with bounded arithmetic. Clang has
  ## already type-checked the declaration; this never evaluates an expression.
  if number.len == 0: return -1
  var base = 10
  var pos = 0
  if number.len >= 2 and number[0] == '0' and number[1] in {'x', 'X'}:
    base = 16
    pos = 2
  elif number[0] == '0': base = 8
  let first = pos
  var value: BiggestInt
  while pos < number.len:
    let ch = number[pos]
    let digit = if ch in {'0'..'9'}: ord(ch) - ord('0')
                elif ch in {'a'..'f'}: ord(ch) - ord('a') + 10
                elif ch in {'A'..'F'}: ord(ch) - ord('A') + 10
                else: -1
    if digit < 0 or digit >= base: break
    if value > (536870912 - digit) div base: return -1
    value = value * base + digit
    inc pos
  if pos == first: return -1
  let suffix = number[pos ..< number.len]
  if suffix notin ["", "u", "U", "l", "L", "ll", "LL", "ul", "uL", "Ul", "UL",
      "lu", "lU", "Lu", "LU", "ull", "uLL", "Ull", "ULL", "llu", "llU", "LLu", "LLU"]:
    return -1
  value

proc explicitAlignment*(tu: CXTranslationUnit, decl, attribute: CXCursor): clonglong =
  ## Only a Clang-classified alignment attribute with a direct integer literal
  ## is modeled. Attribute extents for C11 _Alignas omit the argument in libclang.
  ## Read forward from the attribute's own location, never search by keyword.
  result = -1
  if clang_getCursorKind(attribute) != 441: return
  let location = clang_getCursorLocation(attribute)
  var file: CXFile
  var offset: cuint
  clang_getExpansionLocation(location, addr file, nil, nil, addr offset)
  if file.isNil or clang_equalLocations(location, clang_getLocationForOffset(tu, file, offset)) == 0:
    return # Expansion text must not be mistaken for the source's numeric argument.
  var ts = tokens(tu, attribute)
  if ts == @["_Alignas"]:
    ts = rangeTokens(tu, clang_getRange(clang_getRangeStart(clang_getCursorExtent(attribute)),
      clang_getRangeEnd(clang_getCursorExtent(decl))))
  if ts.len < 4 or ts[0] notin ["_Alignas", "aligned", "__aligned__"] or ts[1] != "(" or ts[3] != ")": return
  let value = alignmentLiteral(ts[2])
  if value < 0 or value > 536870912 or (value > 0 and (value and (value - 1)) != 0): return
  if value == 0 and ts[0] != "_Alignas": return
  result = value

proc stripped(c: CXCursor): CXCursor =
  result = c
  while true:
    let kind = clang_getCursorKind(result)
    if kind in [ckUnexposedExpr, ckParenExpr]:
      let children = collectChildren(result)
      if children.len != 1: break
      result = children[0]
    elif kind == ckCStyleCastExpr:
      # Only an identity conversion can preserve all pointer facts without a
      # separate conversion model. Ignore typedef references, not expressions.
      var operands: seq[CXCursor]
      for child in collectChildren(result):
        if clang_getCursorKind(child) != ckTypeRef: operands.add child
      if operands.len != 1: break
      let target = clang_getCanonicalType(clang_getCursorType(result))
      let source = clang_getCanonicalType(clang_getCursorType(operands[0]))
      if target.kind == tyPointer and $clang_getTypeSpelling(target) == "void *":
        # `(void *)0`, the other spelling of a null pointer constant (C11 6.3.2.3p3), e.g. NULL
        let operand = stripped(operands[0])
        if clang_getCursorKind(operand) == ckIntegerLiteral:
          let evaluated = clang_Cursor_Evaluate(operand)
          if not evaluated.isNil:
            let zero = clang_EvalResult_getKind(evaluated) == CXEval_Int and
              clang_EvalResult_getAsLongLong(evaluated) == 0
            clang_EvalResult_dispose(evaluated)
            if zero:
              result = operand
              break
      if target.kind != tyPointer or source.kind != tyPointer: break
      if clang_equalTypes(target, source) == 0:
        # `void *` to a character pointer, the explicit form of the implicit conversion C already
        # applies: characters need no alignment and may view any object. Qualifiers may be added,
        # never removed.
        let fromType = clang_getPointeeType(source)
        let toType = clang_getPointeeType(target)
        if clang_getCanonicalType(fromType).kind != 2 or
            clang_getCanonicalType(toType).kind notin [4.cint, 5.cint, 13.cint, 14.cint]: break
        let fromSpelling = $clang_getTypeSpelling(clang_getCanonicalType(fromType))
        let toSpelling = $clang_getTypeSpelling(clang_getCanonicalType(toType))
        if (clang_isConstQualifiedType(fromType) != 0 and clang_isConstQualifiedType(toType) == 0) or
            ("volatile" in fromSpelling and "volatile" notin toSpelling) or
            "_Atomic" in fromSpelling or "_Atomic" in toSpelling: break
      result = operands[0]
    else: break

proc expansion(tu: CXTranslationUnit, location: CXSourceLocation):
    tuple[file: CXFile, offset: int, at: CXSourceLocation, direct: bool] =
  ## Where a location is written in a source file, and whether it is written there directly
  ## rather than produced by a macro.
  var file: CXFile
  var offset: cuint
  clang_getExpansionLocation(location, addr file, nil, nil, addr offset)
  if file.isNil: return
  result.file = file
  result.offset = int(offset)
  result.at = clang_getLocationForOffset(tu, file, offset)
  result.direct = clang_equalLocations(result.at, location) != 0

proc binaryOperator(tu: CXTranslationUnit, c: CXCursor): string =
  ## The operator token, read from the source between the two operands, both bounded in one file.
  ## An operand produced by a macro is bounded by where the macro is invoked: a right operand by
  ## the invocation's start, a left operand only when the invocation is a single name, which must
  ## then be followed by exactly the operator. An operator that itself comes from a macro, or two
  ## operands from one invocation, leave no such token and stay unrecognized.
  let children = collectChildren(c)
  if children.len != 2: return
  let left = expansion(tu, clang_getRangeEnd(clang_getCursorExtent(children[0])))
  let right = expansion(tu, clang_getRangeStart(clang_getCursorExtent(children[1])))
  if left.file.isNil or right.file.isNil or
      clang_equalLocations(clang_getLocationForOffset(tu, left.file, 0),
                           clang_getLocationForOffset(tu, right.file, 0)) == 0: return
  if left.direct:
    if left.offset >= right.offset: return
    let between = rangeTokens(tu, clang_getRange(left.at, right.at), left.offset, right.offset)
    if between.len == 1: result = between[0]
  else:
    # the range end of a macro operand maps to the start of its invocation: expect the macro's
    # own single name token, then the operator
    if left.offset >= right.offset: return
    let between = rangeTokens(tu, clang_getRange(left.at, right.at), left.offset, right.offset)
    if between.len == 2 and between[0].len > 0 and between[0][0] in IdentStartChars: result = between[1]

const pureBinary = ["+", "-", "*", "/", "%", "<<", ">>",
  "<", ">", "<=", ">=", "==", "!=", "&", "^", "|", "&&", "||", ","]

proc fixedTypeQuery*(tu: CXTranslationUnit, original: CXCursor): bool =
  let c = stripped(original)
  if clang_getCursorKind(c) != 136: return false # CXCursor_UnaryExpr
  let ts = tokens(tu, c)
  if ts.len < 2 or ts[0] notin ["sizeof", "_Alignof"]: return false
  let children = collectChildren(c)
  if children.len == 0:
    # Builtin type spellings only: no typedef/VLA bounds or expressions hidden
    # in a type name. Those require a separate variably-modified type model.
    for token in ts[1..^1]:
      if token notin ["(", ")", "*", "char", "short", "int", "long", "signed", "unsigned",
          "float", "double", "_Bool", "const", "volatile", "void"]: return false
  elif children.len == 1 and ts[0] == "sizeof":
    let operand = stripped(children[0])
    let kind = clang_getCursorKind(operand)
    if kind != ckDeclRefExpr:
      let parts = collectChildren(operand)
      let spelling = tokens(tu, operand)
      if kind != ckUnaryOperator or parts.len != 1 or spelling.len == 0 or spelling[0] != "*" or
          clang_getCursorKind(stripped(parts[0])) != ckDeclRefExpr: return false
    if clang_Type_getSizeOf(clang_getCursorType(operand)) <= 0: return false
  else: return false
  let evaluated = clang_Cursor_Evaluate(c)
  if evaluated.isNil: return false
  defer: clang_EvalResult_dispose(evaluated)
  clang_EvalResult_getKind(evaluated) == CXEval_Int and clang_EvalResult_getAsLongLong(evaluated) > 0

proc simple(tu: CXTranslationUnit, c: CXCursor): bool =
  let c = stripped(c)
  if fixedTypeQuery(tu, c): return true
  let children = collectChildren(c)
  case clang_getCursorKind(c)
  of ckIntegerLiteral, 107, 110: return true # floating / character literals
  of ckDeclRefExpr:
    let typ = $clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(c)))
    return "volatile" notin typ and "_Atomic" notin typ
  of ckUnaryOperator:
    let ts = tokens(tu, c)
    if ts.len == 0 or ts[0] notin ["&", "!", "+", "-", "~"]: return false
  of ckBinaryOperator:
    # Absence of '=' in macro tokens is not positive evidence of purity.
    if binaryOperator(tu, c) notin pureBinary: return false
  else: return false
  for child in children:
    if not simple(tu, child): return false
  true

proc storagePermission(typ: CXType, depth = 0): string =
  let typ = clang_getCanonicalType(typ)
  if clang_isConstQualifiedType(typ) != 0: return "readonly"
  if depth >= 32: return "unknown"
  if typ.kind == tyConstantArray:
    return storagePermission(clang_getArrayElementType(typ), depth + 1)
  if typ.kind == 105: # CXType_Record: partial const subobjects need field ranges.
    for field in collectChildren(clang_getTypeDeclaration(typ)):
      if clang_getCursorKind(field) == ckFieldDecl and
          storagePermission(clang_getCursorType(field), depth + 1) != "writable":
        return "unknown"
  "writable"

proc literalOffset(tu: CXTranslationUnit, c: CXCursor): bool =
  let value = stripped(c)
  if clang_getCursorKind(value) == ckIntegerLiteral: return true
  if fixedTypeQuery(tu, value): return true
  if clang_getCursorKind(value) == ckUnaryOperator:
    let parts = collectChildren(value)
    let ts = tokens(tu, value)
    return parts.len == 1 and ts.len > 0 and ts[0] in ["+", "-"] and literalOffset(tu, parts[0])

proc shifted(tu: CXTranslationUnit, base: JsonNode, pointer, index: CXCursor,
             subtract = false): JsonNode =
  result = base
  if base["kind"].getStr notin ["address", "pointer", "lastPointer"]: return
  # Retain each step separately: an out-of-range intermediate pointer cannot
  # become valid by a later subtraction. Unknown steps remain unknown.
  if not result.hasKey("offsets"): result["offsets"] = newJArray()
  var step = newJNull()
  if literalOffset(tu, index):
    let evaluated = clang_Cursor_Evaluate(index)
    if not evaluated.isNil:
      defer: clang_EvalResult_dispose(evaluated)
      if clang_EvalResult_getKind(evaluated) == CXEval_Int:
        var representable = true
        if clang_EvalResult_isUnsignedInt(evaluated) != 0:
          representable = clang_EvalResult_getAsUnsigned(evaluated) <= culonglong(high(BiggestInt))
        let number = clang_EvalResult_getAsLongLong(evaluated)
        let typ = clang_getCanonicalType(clang_getCursorType(stripped(pointer)))
        let element = if typ.kind == tyPointer: clang_getPointeeType(typ)
                      else: clang_getArrayElementType(typ)
        let width = clang_Type_getSizeOf(element)
        if representable and number != low(BiggestInt) and width > 0 and abs(number) <= high(BiggestInt) div width:
          let bytes = number * width
          step = %(if subtract: -bytes else: bytes)
  result["offsets"].add step

proc pointerOperands(tu: CXTranslationUnit, parts: seq[CXCursor], commutative = true): seq[CXCursor] =
  if parts.len != 2: return
  for baseIndex in 0..(if commutative: 1 else: 0):
    let index = 1 - baseIndex
    let baseType = clang_getCanonicalType(clang_getCursorType(stripped(parts[baseIndex]))).kind
    let indexType = clang_getCanonicalType(clang_getCursorType(stripped(parts[index]))).kind
    if baseType in [tyPointer, tyConstantArray] and
        (indexType in 3.cint..20.cint or indexType == tyEnum) and simple(tu, parts[index]):
      return @[parts[baseIndex], parts[index]]

proc argument(tu: CXTranslationUnit, c: CXCursor): JsonNode =
  let c = stripped(c)
  let kind = clang_getCursorKind(c)
  if kind == ckIntegerLiteral:
    let evaluated = clang_Cursor_Evaluate(c)
    if not evaluated.isNil:
      let zero = clang_EvalResult_getKind(evaluated) == CXEval_Int and clang_EvalResult_getAsLongLong(evaluated) == 0
      clang_EvalResult_dispose(evaluated)
      if zero: return %*{"kind": "null"}
  if kind in [ckCallExpr, 116] and clang_getCanonicalType(clang_getCursorType(c)).kind == tyPointer:
    return %*{"kind": "lastPointer"}
  if kind == ckUnaryOperator:
    let ts = tokens(tu, c)
    let children = collectChildren(c)
    if ts.len > 0 and ts[0] == "&" and children.len == 1:
      let value = stripped(children[0])
      if clang_getCursorKind(value) == ckDeclRefExpr:
        return %*{"kind": "address", "symbol": usr(clang_getCursorReferenced(value))}
      if clang_getCursorKind(value) == ckArraySubscriptExpr:
        let parts = pointerOperands(tu, collectChildren(value))
        if parts.len == 2:
          return shifted(tu, argument(tu, parts[0]), parts[0], parts[1])
  if kind == ckDeclRefExpr:
    let typ = clang_getCanonicalType(clang_getCursorType(c)).kind
    if typ == tyPointer:
      return %*{"kind": "pointer", "symbol": usr(clang_getCursorReferenced(c))}
    if typ == tyConstantArray:
      return %*{"kind": "address", "symbol": usr(clang_getCursorReferenced(c))}
  if kind == ckBinaryOperator and binaryOperator(tu, c) in ["+", "-"]:
    let parts = pointerOperands(tu, collectChildren(c), binaryOperator(tu, c) == "+")
    if parts.len == 2:
      let base = argument(tu, parts[0])
      if base["kind"].getStr in ["address", "pointer", "lastPointer"]:
        return shifted(tu, base, parts[0], parts[1], binaryOperator(tu, c) == "-")
  # A compile-time integer constant (`64`, `sizeof(buf)`) keeps its value, so a byte count passed
  # to a mark-setting API or a borrow is a fact rather than a guess. Only what Clang folds as a
  # constant expression; no run-time value is inferred.
  if clang_getCanonicalType(clang_getCursorType(c)).kind != tyPointer:
    let evaluated = clang_Cursor_Evaluate(c)
    if not evaluated.isNil:
      let isInt = clang_EvalResult_getKind(evaluated) == CXEval_Int
      let value = if isInt: clang_EvalResult_getAsLongLong(evaluated) else: 0
      clang_EvalResult_dispose(evaluated)
      if isInt: return %*{"kind": "value", "constant": value}
  if simple(tu, c): return %*{"kind": "value"}
  %*{"kind": "unknown"}

proc memoryNode(c: CXCursor, value: JsonNode, mode: string, optional = false): JsonNode =
  %*{"kind": "memory", "line": startLine(c), "value": value,
    "mode": mode, "optional": optional,
    "accessBytes": max(0.clonglong, clang_Type_getSizeOf(clang_getCursorType(c))),
    "accessAlignment": max(0.clonglong, clang_Type_getAlignOf(clang_getCursorType(c)))}

proc pointee(tu: CXTranslationUnit, c: CXCursor): JsonNode =
  let c = stripped(c)
  let typ = $clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(c)))
  if "volatile" in typ or "_Atomic" in typ: return %*{"kind": "unknown"}
  let parts = collectChildren(c)
  let kind = clang_getCursorKind(c)
  if kind == ckDeclRefExpr and (clang_getCanonicalType(clang_getCursorType(c)).kind in 2.cint..32.cint or
      clang_getCanonicalType(clang_getCursorType(c)).kind == tyEnum):
    return %*{"kind": "address", "symbol": usr(clang_getCursorReferenced(c))}
  if kind == ckArraySubscriptExpr:
    let operands = pointerOperands(tu, parts)
    if operands.len == 2:
      return shifted(tu, argument(tu, operands[0]), operands[0], operands[1])
  if kind == ckUnaryOperator and parts.len == 1:
    let ts = tokens(tu, c)
    if ts.len > 0 and ts[0] == "*": return argument(tu, parts[0])
  %*{"kind": "unknown"}

proc statusExpression(tu: CXTranslationUnit, original: CXCursor): JsonNode

proc integerValue(c: CXCursor): tuple[ok: bool, value: BiggestInt] =
  ## The value of an integer constant expression, when it fits the analyzer's integers.
  let evaluated = clang_Cursor_Evaluate(c)
  if evaluated.isNil: return
  defer: clang_EvalResult_dispose(evaluated)
  if clang_EvalResult_getKind(evaluated) != CXEval_Int: return
  if clang_EvalResult_isUnsignedInt(evaluated) != 0:
    let value = clang_EvalResult_getAsUnsigned(evaluated)
    if value > culonglong(high(BiggestInt)): return
    return (true, BiggestInt(value))
  (true, BiggestInt(clang_EvalResult_getAsLongLong(evaluated)))

proc mmioTarget(tu: CXTranslationUnit, original: CXCursor): tuple[found, ok: bool, address, width: BiggestInt, reason: string] =
  ## A volatile access at an address fixed by an integer constant: `*(volatile T *)K` or
  ## `((S *)K)->field`. `found` says the expression has that shape; `ok` that its address and width
  ## are established. Anything else is left to the ordinary rules.
  let c = stripped(original)
  let typ = clang_getCanonicalType(clang_getCursorType(c))
  if "volatile" notin $clang_getTypeSpelling(typ): return
  proc constantBase(pointer: CXCursor): tuple[ok: bool, address: BiggestInt, pointee: CXType] =
    let conversion = stripped(pointer)
    if clang_getCursorKind(conversion) != ckCStyleCastExpr: return
    if clang_getCanonicalType(clang_getCursorType(conversion)).kind != tyPointer: return
    var operands: seq[CXCursor]
    for child in collectChildren(conversion):
      if clang_getCursorKind(child) != ckTypeRef: operands.add child
    if operands.len != 1 or clang_getCanonicalType(clang_getCursorType(operands[0])).kind notin 3.cint..20.cint: return
    let value = integerValue(operands[0])
    if not value.ok or value.value < 0: return
    (true, value.value, clang_getCanonicalType(clang_getPointeeType(clang_getCanonicalType(clang_getCursorType(conversion)))))
  let parts = collectChildren(c)
  let kind = clang_getCursorKind(c)
  if kind == ckUnaryOperator and parts.len == 1:
    let base = constantBase(parts[0])
    if not base.ok or clang_equalTypes(base.pointee, typ) == 0: return
    result.found = true
    let width = clang_Type_getSizeOf(typ)
    if width <= 0: result.reason = "register access width is not established"; return
    return (true, true, base.address, BiggestInt(width), "")
  if kind == ckMemberRefExpr and parts.len == 1:
    let base = constantBase(parts[0])
    if not base.ok or base.pointee.kind != 105: return        # CXType_Record: `->` on a register block
    result.found = true
    let field = clang_getCursorReferenced(c)
    if clang_Cursor_isBitField(field) != 0: result.reason = "bit-field register access is not modeled"; return
    let offset = clang_Cursor_getOffsetOfField(field)
    let width = clang_Type_getSizeOf(typ)
    if offset < 0 or offset mod 8 != 0 or width <= 0:
      result.reason = "register field position is not established"; return
    return (true, true, base.address + BiggestInt(offset div 8), BiggestInt(width), "")

proc mmioNode(c: CXCursor, target: tuple[found, ok: bool, address, width: BiggestInt, reason: string],
              mode: string, operation = "", value: JsonNode = newJNull()): JsonNode =
  if not target.ok:
    return %*{"kind": "unknown", "line": startLine(c), "reason": target.reason}
  %*{"kind": "mmio", "line": startLine(c), "mode": mode, "address": target.address,
    "width": target.width, "operation": operation, "value": value}

proc reads(tu: CXTranslationUnit, c: CXCursor): tuple[ok: bool, nodes: seq[JsonNode]] =
  let c = stripped(c)
  if fixedTypeQuery(tu, c): return (true, @[])
  let kind = clang_getCursorKind(c)
  let parts = collectChildren(c)
  let typ = $clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(c)))
  let register = mmioTarget(tu, c)
  if register.found:
    if not register.ok: return
    return (true, @[mmioNode(c, register, "read")])
  if "volatile" in typ or "_Atomic" in typ: return
  case kind
  of ckIntegerLiteral, 107, 110: result.ok = true; return
  of ckDeclRefExpr:
    result.ok = true
    if clang_getCanonicalType(clang_getCursorType(c)).kind == tyPointer:
      result.nodes.add %*{"kind": "pointerValue", "line": startLine(c), "value": argument(tu, c)}
    if clang_getCanonicalType(clang_getCursorType(c)).kind notin
        [tyPointer, tyConstantArray, tyIncompleteArray, tyVariableArray, tyDependentSizedArray]:
      result.nodes.add memoryNode(c, %*{"kind": "address", "symbol": usr(clang_getCursorReferenced(c))}, "read", true)
    return
  of ckArraySubscriptExpr:
    let value = pointee(tu, c)
    if value["kind"].getStr == "unknown": return
    let base = reads(tu, parts[0])
    let index = reads(tu, parts[1])
    if not base.ok or not index.ok: return
    result.nodes = base.nodes & index.nodes & @[memoryNode(c, value, "read")]
    result.ok = true
    return
  of 116: # CXCursor_ConditionalOperator: scalar read-only arms only.
    let valueType = clang_getCanonicalType(clang_getCursorType(c)).kind
    if parts.len != 3 or (valueType notin 3.cint..20.cint and valueType != tyEnum): return
    let condition = reads(tu, parts[0])
    let yes = reads(tu, parts[1])
    let no = reads(tu, parts[2])
    if not condition.ok or not yes.ok or not no.ok: return
    let branch = %*{"kind": "if", "line": startLine(c), "condition": "unknown",
      "conditionValue": statusExpression(tu, parts[0]),
      "then": {"kind": "sequence", "line": startLine(parts[1]), "children": yes.nodes},
      "else": {"kind": "sequence", "line": startLine(parts[2]), "children": no.nodes}}
    return (true, condition.nodes & @[branch])
  of ckUnaryOperator:
    let ts = tokens(tu, c)
    if ts.len == 0 or parts.len != 1: return
    if ts[0] == "&":
      let value = stripped(parts[0])
      if clang_getCursorKind(value) == ckDeclRefExpr: result.ok = true; return
      if clang_getCursorKind(value) == ckArraySubscriptExpr:
        let children = collectChildren(value)
        if children.len == 2 and argument(tu, c)["kind"].getStr != "unknown":
          let base = reads(tu, children[0])
          let index = reads(tu, children[1])
          return (base.ok and index.ok, base.nodes & index.nodes &
            @[%*{"kind": "pointerFormation", "line": startLine(c), "value": argument(tu, c)}])
      return
    if ts[0] == "*":
      let value = pointee(tu, c)
      if value["kind"].getStr == "unknown": return
      let base = reads(tu, parts[0])
      if not base.ok: return
      result.ok = true
      result.nodes = base.nodes & @[memoryNode(c, value, "read")]
      return
    if ts[0] notin ["!", "+", "-", "~"]: return
  of ckBinaryOperator:
    let op = binaryOperator(tu, c)
    if op notin pureBinary: return
    if op in ["&&", "||"]:
      let evaluated = clang_Cursor_Evaluate(parts[0])
      if not evaluated.isNil:
        let known = clang_EvalResult_getKind(evaluated) == CXEval_Int
        let truth = known and clang_EvalResult_getAsLongLong(evaluated) != 0
        clang_EvalResult_dispose(evaluated)
        if known and ((op == "&&" and not truth) or (op == "||" and truth)):
          return reads(tu, parts[0])
      let left = reads(tu, parts[0])
      let right = reads(tu, parts[1])
      if not left.ok or not right.ok: return
      let evaluatedRight = %*{"kind": "sequence", "line": startLine(parts[1]), "children": right.nodes}
      let skippedRight = %*{"kind": "sequence", "line": startLine(c), "children": []}
      let branch = %*{"kind": "if", "line": startLine(c), "condition": "unknown",
        "conditionValue": statusExpression(tu, parts[0]),
        "then": (if op == "&&": evaluatedRight else: skippedRight),
        "else": (if op == "&&": skippedRight else: evaluatedRight)}
      return (true, left.nodes & @[branch])
  of 119: discard # array initializer list; declarations still reject record initialization
  else: return
  for child in parts:
    let childReads = reads(tu, child)
    if not childReads.ok: return (false, @[])
    result.nodes.add childReads.nodes
  if kind == ckBinaryOperator and binaryOperator(tu, c) in ["+", "-"] and
      clang_getCanonicalType(clang_getCursorType(c)).kind == tyPointer:
    result.nodes.add %*{"kind": "pointerFormation", "line": startLine(c), "value": argument(tu, c)}
  if kind == ckBinaryOperator and binaryOperator(tu, c) == "-" and parts.len == 2 and
      clang_getCanonicalType(clang_getCursorType(parts[0])).kind == tyPointer and
      clang_getCanonicalType(clang_getCursorType(parts[1])).kind == tyPointer:
    result.nodes.add %*{"kind": "pointerDifference", "line": startLine(c),
      "left": argument(tu, parts[0]), "right": argument(tu, parts[1])}
  if kind == ckBinaryOperator and parts.len == 2 and
      binaryOperator(tu, c) in ["<", ">", "<=", ">=", "==", "!="] and
      (clang_getCanonicalType(clang_getCursorType(parts[0])).kind == tyPointer or
       clang_getCanonicalType(clang_getCursorType(parts[1])).kind == tyPointer):
    result.nodes.add %*{"kind": "pointerComparison", "line": startLine(c),
      "operator": binaryOperator(tu, c), "left": argument(tu, parts[0]), "right": argument(tu, parts[1])}
  result.ok = true

proc preceded(n: JsonNode, prefix: seq[JsonNode]): JsonNode =
  if prefix.len == 0: return n
  %*{"kind": "sequence", "line": n["line"], "children": prefix & @[n]}

proc pointerUpdate(c, target: CXCursor, value: JsonNode, prefix: seq[JsonNode]): JsonNode =
  preceded(%*{"kind": "pointerStore", "line": startLine(c),
    "symbol": usr(clang_getCursorReferenced(target)), "value": value},
    prefix & @[%*{"kind": "pointerFormation", "line": startLine(c), "value": value}])

proc statusExpression(tu: CXTranslationUnit, original: CXCursor): JsonNode =
  let c = stripped(original)
  let kind = clang_getCursorKind(c)
  let children = collectChildren(c)
  if kind == 116 and children.len == 3 and clang_getCanonicalType(clang_getCursorType(c)).kind == 17:
    return %*{"kind": "choice", "condition": statusExpression(tu, children[0]),
      "then": statusExpression(tu, children[1]), "else": statusExpression(tu, children[2])}
  if kind == ckDeclRefExpr:
    if clang_getCanonicalType(clang_getCursorType(c)).kind == 17:
      return %*{"kind": "variable", "symbol": usr(clang_getCursorReferenced(c))}
    if clang_getCanonicalType(clang_getCursorType(c)).kind == tyPointer:
      return %*{"kind": "pointerTruth", "value": argument(tu, c)}
    return %*{"kind": "unknown"}
  if kind == ckCallExpr:
    return %*{"kind": "lastCall"}
  if kind == ckUnaryOperator and children.len == 1:
    let ts = tokens(tu, c)
    if ts.len > 0 and ts[0] == "!":
      return %*{"kind": "not", "value": statusExpression(tu, children[0])}
  if kind == ckBinaryOperator:
    let op = binaryOperator(tu, c)
    if op in ["==", "!=", "&&", "||"]:
      return %*{"kind": op, "left": statusExpression(tu, children[0]),
        "right": statusExpression(tu, children[1])}
  let evaluated = clang_Cursor_Evaluate(c)
  if not evaluated.isNil:
    defer: clang_EvalResult_dispose(evaluated)
    if clang_EvalResult_getKind(evaluated) == CXEval_Int:
      return %*{"kind": "constant", "value": (if clang_EvalResult_getAsLongLong(evaluated) == 0: "zero" else: "nonzero")}
  %*{"kind": "unknown"}

proc resultCall(tu: CXTranslationUnit, original: CXCursor): tuple[found: bool, cursor: CXCursor] =
  let c = stripped(original)
  let kind = clang_getCursorKind(c)
  let children = collectChildren(c)
  if kind == ckCallExpr and clang_getCanonicalType(clang_getCursorType(c)).kind == 17:
    return (true, c)
  if kind == ckUnaryOperator and children.len == 1:
    let ts = tokens(tu, c)
    if ts.len > 0 and ts[0] == "!": return resultCall(tu, children[0])
  if kind == ckBinaryOperator and binaryOperator(tu, c) in ["==", "!="]:
    for i in 0..1:
      let other = children[1-i]
      let effects = reads(tu, other)
      # Do not reorder a call against a memory read (completion may end a loan).
      if effects.ok and effects.nodes.len == 0 and statusExpression(tu, other)["kind"].getStr == "constant":
        let found = resultCall(tu, children[i])
        if found.found: return found

proc forSlots(tu: CXTranslationUnit, c: CXCursor): seq[int] =
  ## Locate optional header slots using source tokens, then require a one-to-one
  ## correspondence with Clang children. Never guess from the child count.
  var data: ptr CXToken
  var count: cuint
  clang_tokenize(tu, clang_getCursorExtent(c), addr data, addr count)
  defer: clang_disposeTokens(tu, data, count)
  let items = cast[ptr UncheckedArray[CXToken]](data)
  var spellings: seq[string]
  var offsets: seq[int]
  for i in 0 ..< int(count):
    if clang_getTokenKind(items[i]) != tkComment:
      spellings.add $clang_getTokenSpelling(tu, items[i])
      offsets.add offsetOf(clang_getTokenLocation(tu, items[i]))
  if spellings.len < 5 or spellings[0] != "for" or spellings[1] != "(": return
  if offsets[0] != startOffset(c): return
  var depth = 1
  var separators: seq[int]
  var close = -1
  for i in 2 ..< spellings.len:
    if spellings[i] == "(": inc depth
    elif spellings[i] == ")":
      dec depth
      if depth == 0:
        close = i
        break
    elif spellings[i] == ";" and depth == 1: separators.add i
  if close < 0 or separators.len != 2: return
  let bounds = @[1, separators[0], separators[1], close]
  let children = collectChildren(c)
  if children.len == 0 or startOffset(children[^1]) < offsets[close] + 1: return
  var slots = @[-1, -1, -1, children.len - 1]
  for i in 0 ..< children.len - 1:
    var found = false
    for slot in 0..2:
      if startOffset(children[i]) > offsets[bounds[slot]] and
          startOffset(children[i]) < offsets[bounds[slot+1]] and
          endOffset(children[i]) <= offsets[bounds[slot+1]] + (if slot == 0: 1 else: 0):
        if slots[slot] >= 0: return
        slots[slot] = i
        found = true
        break
    if not found: return
  for slot in 0..2:
    if (bounds[slot+1] > bounds[slot] + 1) != (slots[slot] >= 0): return
  slots

proc boundedSignedCounter(tu: CXTranslationUnit, decl, condition, body, update: CXCursor): bool =
  ## A signed `for` counter update that cannot overflow: the update is `i++`/`++i` under the
  ## condition `i < E` (or `E > i`), or `i--`/`--i` under `i > E` (or `E < i`), compared in the
  ## counter's own type. The condition then bounds i below the type's maximum (above its minimum)
  ## whenever the update runs, provided nothing changes i between the test and the update: i is an
  ## automatic variable or parameter of this C function, its address is never formed, and inside
  ## the condition and body it is only read. Any other form stays unsupported.
  if clang_getCursorLanguage(decl) != 1: return
  let operand = block:
    let u = stripped(update)
    if clang_getCursorKind(u) != ckUnaryOperator: return
    let parts = collectChildren(u)
    if parts.len != 1: return
    parts[0]
  let target = stripped(operand)
  let ts = tokens(tu, stripped(update))
  let names = tokens(tu, target)
  if clang_getCursorKind(target) != ckDeclRefExpr or names.len != 1 or ts.len != 2: return
  let increment =
    if (ts[0] == "++" and ts[1] == names[0]) or (ts[1] == "++" and ts[0] == names[0]): true
    elif (ts[0] == "--" and ts[1] == names[0]) or (ts[1] == "--" and ts[0] == names[0]): false
    else: return
  let counter = clang_getCursorReferenced(target)
  let counterType = clang_getCanonicalType(clang_getCursorType(counter))
  # int, long, long long: no promotion, so the update is arithmetic in the counter's own type
  if clang_getCursorKind(counter) notin [ckVarDecl, ckParmDecl] or counterType.kind notin 17.cint..19.cint: return
  let spelling = $clang_getTypeSpelling(counterType)
  if "volatile" in spelling or "_Atomic" in spelling: return
  if clang_Cursor_getStorageClass(counter) in [scStatic, scExtern] or
      clang_equalCursors(clang_getCursorSemanticParent(counter), decl) == 0: return
  let test = stripped(condition)
  if clang_getCursorKind(test) != ckBinaryOperator: return
  let sides = collectChildren(test)
  if sides.len != 2: return
  let op = binaryOperator(tu, test)
  let side =
    if (increment and op == "<") or (not increment and op == ">"): 0
    elif (increment and op == ">") or (not increment and op == "<"): 1
    else: return
  let compared = stripped(sides[side])
  if clang_getCursorKind(compared) != ckDeclRefExpr or
      clang_equalCursors(clang_getCursorReferenced(compared), counter) == 0: return
  # both operands converted to the counter's type, not to a wider common type
  for s in sides:
    if clang_getCanonicalType(clang_getCursorType(s)).kind != counterType.kind: return
  # every reference: a plain read, or (outside the condition and body) a direct assignment
  var guarded: seq[tuple[first, last: int]]
  guarded.add (startOffset(condition), endOffset(condition))
  guarded.add (startOffset(body), endOffset(body))
  var ok = true
  proc scan(c: CXCursor, ancestors: seq[CXCursor]) =
    if not ok: return
    if clang_getCursorKind(c) == ckDeclRefExpr and
        clang_equalCursors(clang_getCursorReferenced(c), counter) != 0:
      if startOffset(c) == startOffset(target) and endOffset(c) == endOffset(target): return
      var i = ancestors.len - 1
      var child = c
      while i >= 0 and clang_getCursorKind(ancestors[i]) == ckParenExpr:
        child = ancestors[i]
        dec i
      if i < 0: ok = false; return
      let parent = ancestors[i]
      let kind = clang_getCursorKind(parent)
      if kind == ckUnexposedExpr: return               # lvalue-to-rvalue conversion: a read
      var write = false
      if kind == ckUnaryOperator:
        let t = tokens(tu, parent)
        write = t.len > 0 and (t[0] in ["++", "--"] or t[^1] in ["++", "--"])
      elif kind in [ckBinaryOperator, ckCompoundAssign]:
        let parts = collectChildren(parent)
        write = parts.len == 2 and startOffset(parts[0]) == startOffset(child) and
          endOffset(parts[0]) == endOffset(child) and
          (kind == ckCompoundAssign or binaryOperator(tu, parent) == "=")
      if not write: ok = false; return
      for g in guarded:
        if startOffset(c) >= g.first and endOffset(c) <= g.last: ok = false; return
      return
    let next = ancestors & @[c]
    for child in collectChildren(c): scan(child, next)
  scan(decl, @[])
  ok

proc collectProtocolFacts*(tu: CXTranslationUnit, decl: CXCursor): JsonNode =
  let returnsInt = clang_getCanonicalType(clang_getResultType(clang_getCursorType(decl))).kind == 17
  let returnsPointer = clang_getCanonicalType(clang_getResultType(clang_getCursorType(decl))).kind == tyPointer
  proc node(c: CXCursor): JsonNode
  proc expression(c: CXCursor): tuple[ok, calls: bool, prefix: seq[JsonNode], value: JsonNode] =
    let effects = reads(tu, c)
    if effects.ok: return (true, false, effects.nodes, statusExpression(tu, c))
    let value = stripped(c)
    if clang_getCursorKind(value) == ckBinaryOperator and binaryOperator(tu, value) in ["==", "!="]:
      let parts = collectChildren(value)
      if parts.len == 2:
        for pointerIndex in 0..1:
          let nullIndex = 1 - pointerIndex
          if clang_getCanonicalType(clang_getCursorType(stripped(parts[pointerIndex]))).kind != tyPointer: continue
          let nullReads = reads(tu, parts[nullIndex])
          if not nullReads.ok or nullReads.nodes.len != 0 or argument(tu, parts[nullIndex])["kind"].getStr != "null": continue
          let operand = expression(parts[pointerIndex])
          if not operand.ok: return
          let target = argument(tu, parts[pointerIndex])
          let truth = %*{"kind": "pointerTruth", "value": target}
          let comparison = %*{"kind": "pointerComparison", "line": startLine(value),
            "operator": binaryOperator(tu, value), "left": target, "right": {"kind": "null"}}
          return (true, operand.calls, operand.prefix & @[comparison],
            (if binaryOperator(tu, value) == "==": %*{"kind": "not", "value": truth} else: truth))
    if clang_getCursorKind(value) == ckBinaryOperator and
        clang_getCanonicalType(clang_getCursorType(value)).kind == tyPointer and
        binaryOperator(tu, value) in ["+", "-"]:
      let parts = pointerOperands(tu, collectChildren(value), binaryOperator(tu, value) == "+")
      if parts.len != 2 or not literalOffset(tu, parts[1]): return
      let index = reads(tu, parts[1])
      if not index.ok or index.nodes.len != 0: return
      let base = expression(parts[0])
      let target = argument(tu, value)
      if not base.ok or target["kind"].getStr == "unknown": return
      return (true, base.calls, base.prefix & @[%*{"kind": "pointerFormation",
        "line": startLine(value), "value": target}], %*{"kind": "pointerTruth", "value": target})
    if clang_getCursorKind(value) == ckArraySubscriptExpr:
      let typ = clang_getCanonicalType(clang_getCursorType(value))
      let spelling = $clang_getTypeSpelling(typ)
      if (typ.kind notin 3.cint..20.cint and typ.kind != tyEnum) or
          "volatile" in spelling or "_Atomic" in spelling: return
      let parts = pointerOperands(tu, collectChildren(value))
      if parts.len != 2 or not literalOffset(tu, parts[1]): return
      # C does not sequence the two operands. Only accept an index with no
      # evaluated reads or effects, so evaluating the pointer first is sound.
      let index = reads(tu, parts[1])
      if not index.ok or index.nodes.len != 0: return
      let base = expression(parts[0])
      let target = pointee(tu, value)
      if not base.ok or target["kind"].getStr == "unknown": return
      return (true, base.calls, base.prefix & @[memoryNode(value, target, "read")],
        %*{"kind": "unknown"})
    if clang_getCursorKind(value) == ckUnaryOperator:
      let parts = collectChildren(value)
      let ts = tokens(tu, value)
      if parts.len == 1 and ts.len > 0 and ts[0] == "!":
        let operand = expression(parts[0])
        if not operand.ok: return
        return (true, operand.calls, operand.prefix, %*{"kind": "not", "value": operand.value})
      if parts.len == 1 and ts.len > 0 and ts[0] == "&":
        let indexed = stripped(parts[0])
        if clang_getCursorKind(indexed) != ckArraySubscriptExpr: return
        let operands = pointerOperands(tu, collectChildren(indexed))
        if operands.len != 2 or not literalOffset(tu, operands[1]): return
        let index = reads(tu, operands[1])
        if not index.ok or index.nodes.len != 0: return
        let base = expression(operands[0])
        let target = argument(tu, value)
        if not base.ok or target["kind"].getStr == "unknown": return
        # &p[n] forms an address; it does not read the indexed object.
        return (true, base.calls, base.prefix & @[%*{"kind": "pointerFormation",
          "line": startLine(value), "value": target}], %*{"kind": "pointerTruth", "value": target})
      if parts.len == 1 and ts.len > 0 and ts[0] == "*":
        let typ = clang_getCanonicalType(clang_getCursorType(value))
        let spelling = $clang_getTypeSpelling(typ)
        if (typ.kind notin 3.cint..20.cint and typ.kind != tyEnum) or
            "volatile" in spelling or "_Atomic" in spelling: return
        let operand = expression(parts[0])
        let target = pointee(tu, value)
        if not operand.ok or target["kind"].getStr == "unknown": return
        return (true, operand.calls, operand.prefix & @[memoryNode(value, target, "read")],
          %*{"kind": "unknown"})
    if clang_getCursorKind(value) == ckBinaryOperator and binaryOperator(tu, value) in ["&&", "||"]:
      let parts = collectChildren(value)
      if parts.len != 2: return
      let left = expression(parts[0])
      let right = expression(parts[1])
      if not left.ok or not right.ok: return
      let conjunction = binaryOperator(tu, value) == "&&"
      let evaluated = %*{"kind": "sequence", "line": startLine(parts[1]),
        "children": right.prefix & @[%*{"kind": "scalarResult", "line": startLine(parts[1]), "value": right.value}]}
      let skipped = %*{"kind": "scalarResult", "line": startLine(value),
        "value": {"kind": "constant", "value": (if conjunction: "zero" else: "nonzero")}}
      let branch = %*{"kind": "if", "line": startLine(value), "condition": "unknown",
        "conditionValue": left.value,
        "then": (if conjunction: evaluated else: skipped),
        "else": (if conjunction: skipped else: evaluated)}
      return (true, true, left.prefix & @[branch], %*{"kind": "lastCall"})
    if clang_getCursorKind(value) == 116 and
        clang_getCanonicalType(clang_getCursorType(value)).kind == 17:
      let parts = collectChildren(value)
      if parts.len != 3: return
      let condition = expression(parts[0])
      let yes = expression(parts[1])
      let no = expression(parts[2])
      if not condition.ok or not yes.ok or not no.ok: return
      let yesValue = %*{"kind": "scalarResult", "line": startLine(parts[1]), "value": yes.value}
      let noValue = %*{"kind": "scalarResult", "line": startLine(parts[2]), "value": no.value}
      let branch = %*{"kind": "if", "line": startLine(value), "condition": "unknown",
        "conditionValue": condition.value,
        "then": {"kind": "sequence", "line": startLine(parts[1]), "children": yes.prefix & @[yesValue]},
        "else": {"kind": "sequence", "line": startLine(parts[2]), "children": no.prefix & @[noValue]}}
      return (true, true, condition.prefix & @[branch], %*{"kind": "lastCall"})
    if clang_getCursorKind(value) == 116 and
        clang_getCanonicalType(clang_getCursorType(value)).kind == tyPointer:
      let parts = collectChildren(value)
      if parts.len != 3: return
      let condition = expression(parts[0])
      let yes = expression(parts[1])
      let no = expression(parts[2])
      if not condition.ok or not yes.ok or not no.ok: return
      let yesValue = %*{"kind": "pointerResult", "line": startLine(parts[1]), "value": argument(tu, parts[1])}
      let noValue = %*{"kind": "pointerResult", "line": startLine(parts[2]), "value": argument(tu, parts[2])}
      let branch = %*{"kind": "if", "line": startLine(value), "condition": "unknown",
        "conditionValue": condition.value,
        "then": {"kind": "sequence", "line": startLine(parts[1]), "children": yes.prefix & @[yesValue]},
        "else": {"kind": "sequence", "line": startLine(parts[2]), "children": no.prefix & @[noValue]}}
      return (true, condition.calls or yes.calls or no.calls, condition.prefix & @[branch],
        %*{"kind": "pointerTruth", "value": {"kind": "lastPointer"}})
    if clang_getCursorKind(value) == ckCallExpr and
        clang_getCanonicalType(clang_getCursorType(value)).kind == tyPointer:
      let call = node(value)
      call["pointerResultUsed"] = %true
      return (true, true, @[call], %*{"kind": "pointerTruth", "value": {"kind": "lastPointer"}})
    let found = resultCall(tu, c)
    if found.found: return (true, true, @[node(found.cursor)], statusExpression(tu, c))
  proc node(c: CXCursor): JsonNode =
    let kind = clang_getCursorKind(c)
    let children = collectChildren(c)
    result = %*{"kind": "unknown", "line": startLine(c),
      "reason": "unmodeled protocol syntax kind " & $kind}
    case kind
    of ckCompoundStmt, ckDeclStmt:
      result["kind"] = %(if kind == ckCompoundStmt: "scope" else: "sequence")
      result["children"] = newJArray()
      for child in children: result["children"].add node(child)
    of ckVarDecl:
      let typ = clang_getCanonicalType(clang_getCursorType(c)).kind
      if clang_Cursor_getStorageClass(c) in [scStatic, scExtern] or
          typ in [tyVariableArray, tyDependentSizedArray]: return
      var alignment = max(0.clonglong, clang_Type_getAlignOf(clang_getCursorType(c)))
      for child in children:
        if clang_getCursorKind(child) >= 400:
          let explicit = explicitAlignment(tu, c, child)
          if explicit < 0: return
          alignment = max(alignment, explicit)
      let init = clang_Cursor_getVarDeclInitializer(c)
      let hasInit = clang_Cursor_isNull(init) == 0
      var initialReads: seq[JsonNode]
      var initialValue = %*{"kind": "unknown"}
      if hasInit:
        let effects = expression(init)
        if not effects.ok or (effects.calls and typ notin [17.cint, tyPointer]): return
        initialReads = effects.prefix
        initialValue = effects.value
      # A record initializer can encode a resource state; array storage is just a buffer.
      if hasInit and (typ notin [tyPointer, tyConstantArray, tyEnum] and typ notin 2.cint..32.cint): return
      result["kind"] = %"declare"
      result["symbol"] = %usr(c)
      result["pointer"] = %(typ == tyPointer)
      result["storagePermission"] = %storagePermission(clang_getCursorType(c))
      result["storageAlignment"] = %alignment
      result["storageBytes"] = %max(0.clonglong, clang_Type_getSizeOf(clang_getCursorType(c)))
      result["value"] = if hasInit: argument(tu, init) else: %*{"kind": "unknown"}
      if hasInit and typ == 17:
        let assignment = %*{"kind": "scalarStore", "line": startLine(c), "symbol": usr(c), "value": initialValue, "initialization": true}
        result = %*{"kind": "sequence", "line": startLine(c), "children": @[result] & initialReads & @[assignment]}
      else:
        result = preceded(result, initialReads)
    of ckCallExpr:
      let target = clang_getCursorReferenced(c)
      if clang_getCursorKind(target) != ckFunctionDecl: return
      result["kind"] = %"call"
      result["symbol"] = %protocolSymbol(target)
      result["site"] = %startOffset(c)
      result["void"] = %(clang_getCanonicalType(clang_getCursorType(c)).kind == 2)
      result["returnsInt"] = %(clang_getCanonicalType(clang_getCursorType(c)).kind == 17)
      result["returnsPointer"] = %(clang_getCanonicalType(clang_getCursorType(c)).kind == tyPointer)
      result["arguments"] = newJArray()
      result["argumentValues"] = newJArray()
      let count = clang_Cursor_getNumArguments(c)
      if count < 0: result["kind"] = %"unknown"; return
      var argumentReads: seq[JsonNode]
      for i in 0 ..< count:
        let arg = clang_Cursor_getArgument(c, cuint(i))
        let effects = reads(tu, arg)
        if not effects.ok: result["kind"] = %"unknown"; return
        argumentReads.add effects.nodes
        result["arguments"].add argument(tu, arg)
        result["argumentValues"].add (if clang_getCanonicalType(clang_getCursorType(arg)).kind == 17:
          statusExpression(tu, arg) else: %*{"kind": "unknown"})
      result = preceded(result, argumentReads)
    of ckIfStmt:
      if children.len notin [2, 3]: return
      let effects = expression(children[0])
      if not effects.ok: return
      result["conditionValue"] = effects.value
      result["kind"] = %"if"
      result["then"] = node(children[1])
      result["else"] = if children.len == 3: node(children[2]) else: %*{"kind": "sequence", "children": [], "line": startLine(c)}
      result["condition"] = %"unknown"
      let evaluated = clang_Cursor_Evaluate(children[0])
      if not evaluated.isNil:
        if clang_EvalResult_getKind(evaluated) == CXEval_Int:
          result["condition"] = %(if clang_EvalResult_getAsLongLong(evaluated) == 0: "false" else: "true")
        clang_EvalResult_dispose(evaluated)
      result = preceded(result, effects.prefix)
    of ckForStmt:
      let slots = forSlots(tu, c)
      if slots.len != 4: return
      let loop = %*{"kind": "while", "line": startLine(c), "condition": "true",
        "conditionValue": {"kind": "constant", "value": "nonzero"},
        "conditionReads": [], "body": node(children[slots[3]])}
      if slots[1] >= 0:
        let effects = expression(children[slots[1]])
        if not effects.ok: return
        loop["condition"] = %"unknown"
        loop["conditionValue"] = effects.value
        loop["conditionReads"] = %effects.prefix
      if slots[2] >= 0:
        let update = children[slots[2]]
        if slots[1] >= 0 and boundedSignedCounter(tu, decl, children[slots[1]], children[slots[3]], update):
          # the condition rules out overflow; the value after the update is still not tracked
          let operand = stripped(collectChildren(stripped(update))[0])
          let before = reads(tu, operand)
          let target = pointee(tu, operand)
          if not before.ok or target["kind"].getStr == "unknown": return
          loop["increment"] = preceded(memoryNode(operand, target, "write"), before.nodes)
        else:
          loop["increment"] = node(update)
      result = %*{"kind": "scope", "line": startLine(c), "children": []}
      if slots[0] >= 0: result["children"].add node(children[slots[0]])
      result["children"].add loop
    of ckWhileStmt, ckDoStmt:
      if children.len != 2: return
      let conditionIndex = if kind == ckDoStmt: 1 else: 0
      let bodyIndex = 1 - conditionIndex
      let effects = expression(children[conditionIndex])
      if not effects.ok: return
      result["conditionValue"] = effects.value
      result["conditionReads"] = %effects.prefix
      result["kind"] = %(if kind == ckDoStmt: "doWhile" else: "while")
      result["body"] = node(children[bodyIndex])
      result["condition"] = %"unknown"
      let evaluated = clang_Cursor_Evaluate(children[conditionIndex])
      if not evaluated.isNil:
        if clang_EvalResult_getKind(evaluated) == CXEval_Int:
          result["condition"] = %(if clang_EvalResult_getAsLongLong(evaluated) == 0: "false" else: "true")
        clang_EvalResult_dispose(evaluated)
    of ckReturnStmt:
      var returnReads: seq[JsonNode]
      result["value"] = %*{"kind": "unknown"}
      for child in children:
        let effects = expression(child)
        if not effects.ok or (effects.calls and not returnsInt and not returnsPointer): return
        returnReads.add effects.prefix
        if returnsInt: result["value"] = effects.value
        if returnsPointer:
          result["pointerReturn"] = argument(tu, child)
          let value = stripped(child)
          result["nullReturn"] = %(clang_getCursorKind(value) == ckIntegerLiteral and
            statusExpression(tu, value).getOrDefault("value").getStr == "zero")
      result["kind"] = %"return"
      result = preceded(result, returnReads)
    of ckBreakStmt: result["kind"] = %"break"
    of ckContinueStmt: result["kind"] = %"continue"
    of 230: result["kind"] = %"sequence"; result["children"] = newJArray() # null statement
    else:
      # register accesses: a store, a read-modify-write (compound assignment, ++, --)
      if kind in [ckBinaryOperator, ckCompoundAssign] and children.len == 2:
        let register = mmioTarget(tu, children[0])
        if register.found and (kind == ckCompoundAssign or binaryOperator(tu, c) == "="):
          let op = binaryOperator(tu, c)
          if op.len == 0: return
          var prefix: seq[JsonNode]
          let rhs = expression(children[1])
          if rhs.ok: prefix = rhs.prefix
          elif clang_getCursorKind(stripped(children[1])) == ckCallExpr:
            # a value produced by a call: the call's own effects run first, the value is unknown
            let call = node(stripped(children[1]))
            if call["kind"].getStr == "unknown": return call
            prefix = @[call]
          else: return
          let value = integerValue(children[1])
          return preceded(mmioNode(c, register, (if kind == ckCompoundAssign: "update" else: "write"), op,
            (if value.ok: %value.value else: newJNull())), prefix)
      if kind == ckUnaryOperator and children.len == 1 and
          clang_getCursorKind(children[0]) != ckUnexposedExpr:
        # an lvalue operand, not a converted value: ++ or -- of the register itself
        let register = mmioTarget(tu, children[0])
        if register.found:
          return mmioNode(c, register, "update", "step")
      if kind == ckBinaryOperator and binaryOperator(tu, c) in ["&&", "||"]:
        let effects = expression(c)
        if effects.ok:
          return %*{"kind": "sequence", "line": startLine(c), "children": effects.prefix}
      if kind == ckUnaryOperator and children.len == 1:
        let operand = stripped(children[0])
        let ts = tokens(tu, c)
        let operandTokens = tokens(tu, operand)
        let typ = clang_getCanonicalType(clang_getCursorType(operand))
        if clang_getCursorKind(operand) == ckDeclRefExpr and
            typ.kind == tyPointer and operandTokens.len == 1 and ts.len == 2 and
            ((ts[0] in ["++", "--"] and ts[1] == operandTokens[0]) or
             (ts[1] in ["++", "--"] and ts[0] == operandTokens[0])):
          let before = reads(tu, operand)
          let width = clang_Type_getSizeOf(clang_getPointeeType(typ))
          if not before.ok or width <= 0: return
          let value = argument(tu, operand)
          value["offsets"] = %*[(if "--" in ts: -width else: width)]
          result = pointerUpdate(c, operand, value, before.nodes)
          return
        if clang_getCursorKind(operand) == ckDeclRefExpr and
            typ.kind in 4.cint..12.cint and operandTokens.len == 1 and ts.len == 2 and
            ((ts[0] in ["++", "--"] and ts[1] == operandTokens[0]) or
             (ts[1] in ["++", "--"] and ts[0] == operandTokens[0])):
          let before = reads(tu, operand)
          if not before.ok: return
          let target = pointee(tu, operand)
          if target["kind"].getStr == "unknown": return
          # Standalone unsigned updates may wrap. Invalidate scalar facts instead
          # of inventing a monotonic counter or a finite number of iterations.
          result = preceded(memoryNode(operand, target, "write"), before.nodes)
          return
      if kind == ckCompoundAssign and children.len == 2 and
          binaryOperator(tu, c) in ["+=", "-="]:
        let left = stripped(children[0])
        let leftType = clang_getCanonicalType(clang_getCursorType(left))
        let rightType = clang_getCanonicalType(clang_getCursorType(children[1]))
        if clang_getCursorKind(left) == ckDeclRefExpr and leftType.kind == tyPointer and
            rightType.kind in 3.cint..20.cint:
          let before = reads(tu, left)
          let rhs = reads(tu, children[1])
          if not before.ok or not rhs.ok or not simple(tu, children[1]): return
          let value = shifted(tu, argument(tu, left), left, children[1], binaryOperator(tu, c) == "-=")
          result = pointerUpdate(c, left, value, before.nodes & rhs.nodes)
          return
        # Require unsigned arithmetic after the usual integer conversions.
        # Narrow unsigned LHS and wider signed RHS need a separate range model.
        if clang_getCursorKind(left) != ckDeclRefExpr or leftType.kind notin 9.cint..12.cint or
            rightType.kind notin 3.cint..20.cint or
            clang_Type_getSizeOf(rightType) <= 0 or
            clang_Type_getSizeOf(rightType) > clang_Type_getSizeOf(leftType): return
        let before = reads(tu, left)
        let rhs = reads(tu, children[1])
        let target = pointee(tu, left)
        if not before.ok or not rhs.ok or target["kind"].getStr == "unknown": return
        result = preceded(memoryNode(left, target, "write"), before.nodes & rhs.nodes)
        return
      if kind == ckBinaryOperator and binaryOperator(tu, c) == "=" and children.len == 2:
        let target = pointee(tu, children[0])
        let left = stripped(children[0])
        if clang_getCursorKind(left) == ckDeclRefExpr and
            clang_getCanonicalType(clang_getCursorType(left)).kind == tyPointer:
          # A pointer variable assignment changes its binding, not its pointee.
          # A direct visible pointer-returning call can provide the new binding.
          let lhs = reads(tu, left)
          let rhs = expression(children[1])
          if not lhs.ok or not rhs.ok: return
          let value = argument(tu, children[1])
          result = preceded(%*{"kind": "pointerStore", "line": startLine(c),
            "symbol": usr(clang_getCursorReferenced(left)), "value": value}, rhs.prefix)
          return
        if target["kind"].getStr == "lastPointer":
          # The RHS and LHS address are unsequenced in C. Restrict the RHS
          # and subscript to unevaluated/read-free constants, not memory reads.
          let rhs = reads(tu, children[1])
          if not rhs.ok or rhs.nodes.len != 0 or not literalOffset(tu, children[1]): return
          let typ = clang_getCanonicalType(clang_getCursorType(left))
          if typ.kind notin 3.cint..20.cint and typ.kind != tyEnum: return
          let parts = collectChildren(left)
          var base: CXCursor
          if clang_getCursorKind(left) == ckUnaryOperator and parts.len == 1:
            let ts = tokens(tu, left)
            if ts.len == 0 or ts[0] != "*": return
            base = parts[0]
          elif clang_getCursorKind(left) == ckArraySubscriptExpr:
            let operands = pointerOperands(tu, parts)
            if operands.len != 2 or not literalOffset(tu, operands[1]): return
            let index = reads(tu, operands[1])
            if not index.ok or index.nodes.len != 0: return
            base = operands[0]
          else: return
          let location = expression(base)
          if not location.ok: return
          return preceded(memoryNode(left, target, "write"), location.prefix)
        let scalar = clang_getCursorKind(left) == ckDeclRefExpr and
          clang_getCanonicalType(clang_getCursorType(left)).kind == 17
        let effects = expression(children[1])
        if target["kind"].getStr == "unknown" or not effects.ok or (effects.calls and not scalar): return
        var prefix = effects.prefix
        for part in collectChildren(left):
          let locationReads = reads(tu, part)
          if not locationReads.ok: return
          prefix.add locationReads.nodes
        if scalar:
          result = preceded(%*{"kind": "scalarStore", "line": startLine(c),
            "symbol": usr(clang_getCursorReferenced(left)), "value": effects.value}, prefix)
        else:
          result = preceded(memoryNode(c, target, "write"), prefix)
      else:
        let effects = reads(tu, c)
        if effects.ok:
          result = %*{"kind": "sequence", "line": startLine(c), "children": effects.nodes}
  result = %*{"parameters": [], "parameterKinds": [], "parameterBytes": [], "parameterAlignments": [], "parameterPermissions": [], "returnsInt": returnsInt, "returnsPointer": returnsPointer, "body": {"kind": "unknown", "line": startLine(decl)}}
  var unsupportedEntry = false
  for child in collectChildren(decl):
    if clang_getCursorKind(child) == ckParmDecl:
      result["parameters"].add %usr(child)
      result["parameterPermissions"].add %storagePermission(clang_getCursorType(child))
      result["parameterAlignments"].add %max(0.clonglong, clang_Type_getAlignOf(clang_getCursorType(child)))
      result["parameterBytes"].add %max(0.clonglong, clang_Type_getSizeOf(clang_getCursorType(child)))
      result["parameterKinds"].add %clang_getCanonicalType(clang_getCursorType(child)).kind
      # Parameter bounds/attributes can execute before the compound body.
      for part in collectChildren(child):
        if clang_getCursorKind(part) != ckTypeRef: unsupportedEntry = true
    elif clang_getCursorKind(child) == ckCompoundStmt:
      result["body"] = node(child)

  if unsupportedEntry:
    result["body"] = %*{"kind": "unknown", "line": startLine(decl),
      "reason": "parameter bounds or attributes require protocol entry modeling"}
