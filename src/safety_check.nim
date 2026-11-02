## Required source-effect checks. Every call is traversed, including scalar-only
## helpers. External contracts remain explicit assumptions, never proof badges.
import std/[json, os, sets, tables, algorithm, strutils, sha1, sequtils]
import ir, frontend_c, safety_config, clang, protocol_check

const effectCapability = "source-effects.c.v1"

type
  Site = tuple[file: string, line: int]
  Summary = object
    effects: HashSet[string]
    assumptions: HashSet[string]
    findings: seq[JsonNode]
    witnesses: Table[string, tuple[site: Site, chain: seq[string]]]
    boundaries: Table[string, tuple[site: Site, chain: seq[string]]]
    unverified, violation: bool

proc finding(code, status, message: string, site: Site, chain: seq[string]): JsonNode =
  %*{"code": code, "status": status, "message": message,
     "file": site.file, "line": site.line, "callChain": chain}

proc ordered(values: HashSet[string]): seq[string] =
  for value in values: result.add value
  result.sort()

proc checkSafety*(cfg: SafetyConfig): tuple[report: JsonNode, exitCode: int] =
  let clangVersion = $clang_getClangVersion()
  for binding in cfg.compilationBindings:
    if binding.clangVersion != clangVersion:
      fail(binding.source & ": compilation Clang version mismatch")
  var functions = initTable[string, EffectFunction]()
  var unitIssues = initTable[string, seq[string]]()
  var inputHashes = initTable[string, string]()
  var compilation = newJArray()
  var parsedInputs = initHashSet[string]()
  var symbols = initHashSet[string]()
  var checks = cfg.checks
  for item in cfg.inputs:
    if item.path in inputHashes and inputHashes[item.path] != item.digest:
      fail(item.path & ": configured input changed during loading")
    inputHashes[item.path] = item.digest
  for source in cfg.sources:
    if source.splitFile.ext.toLowerAscii notin [".c", ".cc", ".cpp", ".cxx"]:
      fail(source & ": safety checks require a C/C++ translation unit")
    let program = parseCFile(source, cfg.arguments, collectEffects = true)
    let facts = program.effects
    for binding in cfg.targetBindings:
      if facts.targetTriple.len == 0 or facts.pointerWidth <= 0:
        fail(binding.source & ": target information unavailable for " & source)
      if binding.triple != facts.targetTriple or binding.pointerWidth != facts.pointerWidth:
        fail(binding.source & ": target requirements mismatch for " & source &
          "; required " & binding.triple & "/" & $binding.pointerWidth & " bits, observed " &
          facts.targetTriple & "/" & $facts.pointerWidth & " bits")
    for binding in cfg.compilationBindings:
      if binding.arguments != facts.arguments:
        fail(binding.source & ": compilation arguments mismatch for " & source)
    for required in facts.requirements:
      if required.profile notin cfg.profiles: fail(source & ": unknown @verify profile '" & required.profile & "'")
      for fn in facts.functions:
        if fn.symbol == required.symbol:
          let check = SafetyCheck(file: fn.file, function: fn.name,
            symbol: fn.symbol, profile: required.profile)
          if check notin checks: checks.add check
    compilation.add %*{"source": source, "arguments": facts.arguments,
      "target": (if facts.targetTriple.len == 0 or facts.pointerWidth <= 0: newJNull()
                 else: %*{"triple": facts.targetTriple, "pointerWidth": facts.pointerWidth, "unit": "bits"})}
    for item in facts.inputs:
      parsedInputs.incl item.path
      if item.path in inputHashes and inputHashes[item.path] != item.digest:
        fail(item.path & ": input changed during analysis")
      inputHashes[item.path] = item.digest
    for fn in facts.functions:
      if fn.symbol.len == 0: fail(fn.file & ": function has no symbol identity")
      if fn.symbol in functions and functions[fn.symbol] != fn:
        fail(fn.file & ": conflicting definitions/configurations for " & fn.symbol)
      functions[fn.symbol] = fn
      symbols.incl fn.symbol
      # Conservative union: a header seen in an unsupported TU cannot silently
      # lose that uncertainty when another TU sees the same definition.
      for issue in facts.unsupported:
        if issue notin unitIssues.getOrDefault(fn.symbol):
          unitIssues.mgetOrPut(fn.symbol, @[]).add issue
      for call in fn.calls:
        if call.symbol.len > 0: symbols.incl call.symbol
  for artifact in cfg.artifacts:
    if artifact.role == "parsed-input" and artifact.path notin parsedInputs:
      fail(artifact.source & ": required artifact was not parsed: " & artifact.path)
  if checks.len == 0: fail("no configured checks or @verify regions; refusing vacuous success")
  for symbol in cfg.contracts.keys:
    if symbol notin symbols: fail("external contract matches no declaration/call: " & symbol)
  for symbol in cfg.boundaries.keys:
    if symbol notin symbols: fail("function boundary matches no definition/call: " & symbol)
  # No cache is consumed: every invocation re-parses all configured source units.
  # Check snapshots against disk so a mixed-version run cannot claim acceptance.
  for path, digest in inputHashes:
    if not fileExists(path) or $secureHash(readFile(path)) != digest:
      fail(path & ": parsed/configured input differs from current contents")

  proc summarize(root: string, context = "", checkContext = true): Summary =
    var summary: Summary
    var visited, active = initHashSet[string]()
    proc walk(symbol: string, site: Site, chain: seq[string]) =
      if symbol in active:
        summary.effects.incl "recurse"
        summary.witnesses["recurse"] = (site, chain)
        return
      if symbol in visited: return
      visited.incl symbol
      active.incl symbol
      defer: active.excl symbol
      if symbol in cfg.boundaries: summary.boundaries[symbol] = (site, chain)
      if checkContext and symbol in cfg.contracts and cfg.contracts[symbol].contextsDeclared:
        if context.len == 0:
          summary.unverified = true
          summary.findings.add finding("MISSING_EXECUTION_CONTEXT", "unverified",
            "API requires an explicit execution context: " & symbol, site, chain)
        elif context notin cfg.contracts[symbol].contexts:
          summary.violation = true
          summary.findings.add finding("FORBIDDEN_CONTEXT_CALL", "violation",
            "API is not permitted in execution context '" & context & "'", site, chain)
      elif checkContext and context.len > 0 and symbol notin functions:
        summary.unverified = true
        summary.findings.add finding("MISSING_CONTEXT_CONTRACT", "unverified",
          "external API has no execution-context contract: " & symbol, site, chain)
      if symbol in functions:
        let fn = functions[symbol]
        for issue in unitIssues.getOrDefault(symbol):
          summary.unverified = true
          summary.findings.add finding("UNSUPPORTED_EFFECT_MODEL", "unverified", issue,
            (fn.file, fn.first), chain)
        for issue in fn.unsupported:
          summary.unverified = true
          summary.findings.add finding("UNSUPPORTED_EFFECT_MODEL", "unverified", issue.reason,
            (fn.file, issue.line), chain)
        for call in fn.calls:
          let next = chain & @[if call.indirect: "<indirect>" else: call.symbol]
          if call.indirect or call.symbol.len == 0:
            summary.unverified = true
            summary.findings.add finding("UNRESOLVED_EFFECT_CALL", "unverified",
              "cannot establish effects of an indirect/unresolved call",
              (call.file, call.line), next)
          else: walk(call.symbol, (call.file, call.line), next)
      elif symbol in heapPrimitives:
        summary.effects.incl "heap_allocate"
        summary.witnesses["heap_allocate"] = (site, chain)
        # Primitive effects are part of the versioned C effect model. A supplied
        # contract is not allowed to override a known allocator as pure.
        # Knowing that malloc allocates does NOT establish that it never blocks.
        # A complete external contract is still required for its other effects.
        if symbol in cfg.contracts:
          let contract = cfg.contracts[symbol]
          summary.assumptions.incl contract.assumption
          for effect in contract.effects:
            summary.effects.incl effect
            summary.witnesses[effect] = (site, chain)
        else:
          summary.unverified = true
          summary.findings.add finding("INCOMPLETE_EFFECT_CONTRACT", "unverified",
            "allocation is known, but blocking/wait effects need an external contract for " & symbol,
            site, chain)
      elif symbol in cfg.contracts:
        let contract = cfg.contracts[symbol]
        summary.assumptions.incl contract.assumption
        for effect in contract.effects:
          summary.effects.incl effect
          summary.witnesses[effect] = (site, chain)
      else:
        summary.unverified = true
        summary.findings.add finding("MISSING_EFFECT_CONTRACT", "unverified",
          "no analyzed body or external effect contract for " & symbol, site, chain)
    walk(root, (functions[root].file, functions[root].first), @[root])
    if checkContext and context.len > 0:
      for item in summary.findings.mitems: item["executionContext"] = %context
    result = summary

  proc callDepth(root: string): tuple[maximum: int, unknown: bool, chain: seq[string],
      site: Site, assumptions: HashSet[string], findings: seq[JsonNode]] =
    type DepthNode = tuple[bound: int, known: bool, tail: seq[string], site: Site]
    var memo = initTable[string, DepthNode]()
    var active = initHashSet[string]()
    var assumptions = initHashSet[string]()
    var findings: seq[JsonNode]
    var steps = 0
    proc issue(code, message: string, at: Site, chain: seq[string]) =
      findings.add finding(code, "unverified", message, at, chain)
    proc walk(symbol: string, at: Site, chain: seq[string]): DepthNode =
      result = (1, true, @[symbol], at)
      inc steps
      if steps > 10000 or chain.len > 128:
        if steps == 10001 or chain.len > 128:
          issue("CALL_DEPTH_ANALYSIS_LIMIT", "call-depth analysis budget exceeded", at, chain)
        result.known = false
        return
      if symbol in active:
        issue("RECURSIVE_CALL_DEPTH", "finite depth of a recursive call graph is not established", at, chain)
        result.known = false
        return
      if symbol in memo:
        result = memo[symbol]
        # A leaf's diagnostic location belongs to this caller, not the caller
        # that first populated the memo. Longer tails own their internal site.
        if result.tail.len == 1: result.site = at
        return
      active.incl symbol
      defer: active.excl symbol
      if symbol in functions:
        let fn = functions[symbol]
        if fn.unsupported.len > 0 or unitIssues.getOrDefault(symbol).len > 0:
          issue("UNSUPPORTED_CALL_DEPTH", "implicit/unmodeled calls prevent a depth bound", at, chain)
          result.known = false
        for call in fn.calls:
          let next = chain & @[if call.indirect: "<indirect>" else: call.symbol]
          if call.indirect or call.symbol.len == 0:
            issue("UNRESOLVED_CALL_DEPTH", "unresolved callee has no established depth bound", (call.file, call.line), next)
            result.known = false
          else:
            let child = walk(call.symbol, (call.file, call.line), next)
            result.known = result.known and child.known
            if child.bound + 1 > result.bound:
              result.bound = child.bound + 1
              result.tail = @[symbol] & child.tail
              result.site = child.site
      elif symbol in cfg.contracts and cfg.contracts[symbol].maxCallDepth > 0:
        let contract = cfg.contracts[symbol]
        assumptions.incl contract.assumption
        result.bound = contract.maxCallDepth
      else:
        issue("MISSING_CALL_DEPTH_CONTRACT", "external callee requires an explicit maximum call depth", at, chain)
        result.known = false
      # Only completed, fully established subgraphs are reusable. Unresolved
      # recursion, calls or budget exhaustion must never populate proof entries.
      if result.known: memo[symbol] = result
    let depth = walk(root, (functions[root].file, functions[root].first), @[root])
    (depth.bound, not depth.known, depth.tail, depth.site, assumptions, findings)

  proc stackUsage(root: string): tuple[bytes: BiggestInt, unknown: bool, chain: seq[string],
      assumptions: HashSet[string], frames: JsonNode, findings: seq[JsonNode]] =
    ## Worst-case stack along the call graph: each analyzed function's frame from a compiler
    ## stack-usage report (plus the stack each call adds beyond the reported frames), each external
    ## function's declared maxStackBytes. Recursion, unresolved calls, dynamic frames, missing or
    ## stale reports leave the bound unknown.
    type StackNode = tuple[bytes: BiggestInt, known: bool, tail: seq[string]]
    var memo = initTable[string, StackNode]()
    var active = initHashSet[string]()
    var assumptions = initHashSet[string]()
    var findings: seq[JsonNode]
    var frames = newJArray()
    var steps = 0
    proc issue(code, message: string, at: Site, chain: seq[string]) =
      findings.add finding(code, "unverified", message, at, chain)
    proc walk(symbol: string, at: Site, chain: seq[string]): StackNode =
      result = (0.BiggestInt, true, @[symbol])
      inc steps
      if steps > 10000 or chain.len > 128:
        issue("STACK_ANALYSIS_LIMIT", "stack-usage analysis budget exceeded", at, chain)
        result.known = false
        return
      if symbol in active:
        issue("RECURSIVE_STACK_USAGE", "a recursive call graph has no established stack bound", at, chain)
        result.known = false
        return
      if symbol in memo: return memo[symbol]
      active.incl symbol
      defer: active.excl symbol
      if symbol in functions:
        let fn = functions[symbol]
        let key: StackKey = (fn.file, fn.nameLine, fn.name)
        if fn.unsupported.len > 0 or unitIssues.getOrDefault(symbol).len > 0:
          issue("UNSUPPORTED_STACK_USAGE", "implicit or unmodeled calls prevent a stack bound", at, chain)
          result.known = false
        if fn.file in cfg.staleStackSources:
          issue("STALE_STACK_EVIDENCE", "the stack-usage report " & cfg.staleStackSources[fn.file] &
            " was produced from a different version of " & fn.file, (fn.file, fn.first), chain)
          result.known = false
        elif key notin cfg.stackFrames:
          issue("MISSING_STACK_EVIDENCE", "no stack-usage report entry for " & fn.name & " at " & fn.file & ":" &
            $fn.nameLine, (fn.file, fn.first), chain)
          result.known = false
        else:
          let frame = cfg.stackFrames[key]
          assumptions.incl frame.assumption
          let evidence = %*{"symbol": symbol, "frameBytes": frame.bytes, "perCallBytes": frame.perCallBytes,
            "bounded": frame.bounded, "report": frame.report}
          if evidence notin frames.getElems: frames.add evidence
          if not frame.bounded:
            issue("DYNAMIC_STACK_FRAME", "the compiler reports a dynamic, unbounded frame for " & fn.name,
              (fn.file, fn.first), chain)
            result.known = false
          result.bytes = frame.bytes + frame.perCallBytes
        var deepest = 0.BiggestInt
        for call in fn.calls:
          let next = chain & @[if call.indirect: "<indirect>" else: call.symbol]
          if call.indirect or call.symbol.len == 0:
            issue("UNRESOLVED_STACK_USAGE", "unresolved callee has no established stack bound", (call.file, call.line), next)
            result.known = false
          else:
            let child = walk(call.symbol, (call.file, call.line), next)
            result.known = result.known and child.known
            if child.bytes > deepest:
              deepest = child.bytes
              result.tail = @[symbol] & child.tail
        result.bytes += deepest
      elif symbol in cfg.contracts and cfg.contracts[symbol].maxStackBytes >= 0:
        assumptions.incl cfg.contracts[symbol].assumption
        result.bytes = cfg.contracts[symbol].maxStackBytes
      else:
        issue("MISSING_STACK_CONTRACT", "external callee requires a declared maxStackBytes", at, chain)
        result.known = false
      if result.known: memo[symbol] = result
    let usage = walk(root, (functions[root].file, functions[root].first), @[root])
    (usage.bytes, not usage.known, usage.tail, assumptions, frames, findings)

  # Verify available implementations independently; their declarations must not
  # conceal actual effects or unresolved implementation dependencies.
  var contractFindings = initTable[string, seq[JsonNode]]()
  for symbol, contract in cfg.contracts:
    if symbol in heapPrimitives and symbol notin functions:
      if "heap_allocate" notin contract.effects:
        contractFindings[symbol] = @[finding("CONTRACT_EFFECT_MISMATCH", "violation",
          "known allocation primitive cannot be declared nonallocating", (contract.origin, 0), @[symbol])]
    elif symbol in functions:
      let summary = summarize(symbol, checkContext = false)
      for effect in ordered(summary.effects):
        if effect notin contract.effects:
          contractFindings.mgetOrPut(symbol, @[]).add finding("CONTRACT_EFFECT_MISMATCH", "violation",
            "implementation may perform undeclared effect '" & effect & "'",
            (functions[symbol].file, functions[symbol].first), @[symbol])
      if summary.unverified:
        contractFindings.mgetOrPut(symbol, @[]).add finding("CONTRACT_BODY_UNVERIFIED", "unverified",
          "implementation effect contract could not be established",
          (functions[symbol].file, functions[symbol].first), @[symbol])

  for symbol, contract in cfg.contracts:
    if symbol notin functions or not contract.contextsDeclared: continue
    for context in contract.contexts:
      let summary = summarize(symbol, context)
      for item in summary.findings:
        var detail = item.copy()
        detail["executionContext"] = %context
        contractFindings.mgetOrPut(symbol, @[]).add detail
      for effect in cfg.contexts[context]:
        if effect in summary.effects:
          let witness = summary.witnesses[effect]
          var item = finding("CONTRACT_CONTEXT_MISMATCH", "violation",
            "implementation violates context '" & context & "': " & effect,
            witness.site, witness.chain)
          item["executionContext"] = %context
          contractFindings.mgetOrPut(symbol, @[]).add item

  var depthContractAssumptions = initHashSet[string]()
  var depthContractEvidence = newJArray()
  for symbol, contract in cfg.contracts:
    if symbol notin functions or contract.maxCallDepth == 0: continue
    let depth = callDepth(symbol)
    depthContractEvidence.add %*{"symbol": symbol, "declaredMaximum": contract.maxCallDepth,
      "upperBound": (if depth.unknown: newJNull() else: %depth.maximum),
      "assumptions": ordered(depth.assumptions), "callChain": depth.chain, "unit": "source-call-frames"}
    for assumption in depth.assumptions: depthContractAssumptions.incl assumption
    contractFindings.mgetOrPut(symbol, @[]).add depth.findings
    if not depth.unknown and depth.maximum > contract.maxCallDepth:
      contractFindings.mgetOrPut(symbol, @[]).add finding("CONTRACT_CALL_DEPTH_MISMATCH", "violation",
        "implementation call depth " & $depth.maximum & " exceeds declared " & $contract.maxCallDepth,
        depth.site, depth.chain)
  for assumption in depthContractAssumptions:
    if assumption notin cfg.accepted:
      contractFindings.mgetOrPut("<depth-contracts>", @[]).add finding("UNACCEPTED_ASSUMPTION", "conditional",
        "depth contract proof depends on unaccepted external assumption: " & assumption, ("", 0), @[])

  var obligations = newJArray()
  var allFindings = newJArray()
  var overall = if depthContractAssumptions.len > 0: "conditional" else: "verified"
  var accepted = true
  # Contract contradictions are configuration-wide; an unused contradictory
  # contract must not appear as accepted merely because this root avoided it.
  var contractOrder: seq[string]
  for symbol in contractFindings.keys: contractOrder.add symbol
  contractOrder.sort()
  for symbol in contractOrder:
    for item in contractFindings[symbol]:
      allFindings.add item
      accepted = false
      if item["status"].getStr == "violation": overall = "violation"
      elif item["status"].getStr == "unverified" and overall != "violation": overall = "unverified"
  for check in checks:
    var matches: seq[string]
    for symbol, fn in functions:
      if fn.file == check.file and fn.name == check.function and
          (check.symbol.len == 0 or check.symbol == symbol): matches.add symbol
    if matches.len != 1:
      fail(check.file & ": check must identify exactly one definition of '" & check.function & "'; got " & $matches.len)
    let root = matches[0]
    let context = cfg.profileContexts.getOrDefault(check.profile)
    var summary = summarize(root, context)
    var forbidden = cfg.profiles[check.profile]
    if context.len > 0:
      for effect in cfg.contexts[context]:
        if effect notin forbidden: forbidden.add effect
    let fn = functions[root]
    let checkMemory = check.profile in cfg.memoryProfiles
    let selectedProtocols = cfg.protocolProfiles.getOrDefault(check.profile)
    var protocolScope = newJNull()
    var capacityEvidence, alignmentEvidence, accessCapacityEvidence, accessAlignmentEvidence, sourceAccessEvidence, pointerFormationEvidence, regionEvidence, mmioEvidence, resourceEvidence: seq[JsonNode]
    if selectedProtocols.len > 0 or cfg.requiresMemoryAccess or checkMemory or check.profile in cfg.heapBudgets:
      let owner = if fn.protocolOwner.len > 0: fn.protocolOwner else: root
      if owner notin functions: fail("missing enclosing protocol function: " & owner)
      let ownerFn = functions[owner]
      protocolScope = %*{"symbol": owner, "file": ownerFn.file,
        "firstLine": ownerFn.first, "lastLine": ownerFn.last,
        "kind": (if fn.protocolOwner.len > 0: "enclosing-function" else: "function")}
      if fn.protocolOwner.len > 0:
        # The state before/after the block depends on the whole owner. Include
        # every external premise and uncertainty without widening block effects.
        let dependencies = summarize(owner, context)
        for assumption in dependencies.assumptions: summary.assumptions.incl assumption
        summary.findings.add dependencies.findings
        summary.unverified = summary.unverified or dependencies.unverified
        summary.violation = summary.violation or dependencies.violation
        for symbol, witness in dependencies.boundaries: summary.boundaries[symbol] = witness
    for symbol, witness in summary.boundaries:
      for boundary in cfg.boundaries[symbol]:
        if boundary.protocol notin selectedProtocols:
          summary.unverified = true
          summary.findings.add finding("MISSING_BOUNDARY_PROTOCOL", "unverified",
            "called function boundary requires selected protocol '" & boundary.protocol & "'",
            witness.site, witness.chain)
    if selectedProtocols.len > 0 or cfg.requiresMemoryAccess or checkMemory or check.profile in cfg.heapBudgets:
      let protocolResult = checkProtocols(cfg, functions, root, selectedProtocols, checkMemory,
                                          cfg.heapBudgets.getOrDefault(check.profile, -1))
      summary.findings.add protocolResult.findings
      capacityEvidence = protocolResult.capacityEvidence
      accessCapacityEvidence = protocolResult.accessCapacityEvidence
      accessAlignmentEvidence = protocolResult.accessAlignmentEvidence
      sourceAccessEvidence = protocolResult.sourceAccessEvidence
      pointerFormationEvidence = protocolResult.pointerFormationEvidence
      alignmentEvidence = protocolResult.alignmentEvidence
      regionEvidence = protocolResult.regionEvidence
      mmioEvidence = protocolResult.mmioEvidence
      resourceEvidence = protocolResult.resourceEvidence
      for assumption in protocolResult.assumptions: summary.assumptions.incl assumption
      summary.unverified = summary.unverified or protocolResult.unverified
      summary.violation = summary.violation or protocolResult.violation
    var stackEvidence = newJNull()
    if check.profile in cfg.stackBudgets:
      let usage = stackUsage(root)
      let limit = cfg.stackBudgets[check.profile]
      summary.findings.add usage.findings
      var unknown = usage.unknown
      for assumption in usage.assumptions: summary.assumptions.incl assumption
      var frames = usage.frames
      # Interrupts that may preempt this code add their own stack on top: along a chain of
      # strictly rising priorities when they nest, one handler at a time when they do not.
      var interruptBytes = 0.BiggestInt
      var interruptChain: seq[string]
      if cfg.interruptNesting.len > 0:
        var own = -1
        for h in cfg.interruptHandlers:
          if h.symbol == root: own = h.priority
        var candidates: seq[tuple[symbol: string, priority: int, bytes: BiggestInt]]
        for h in cfg.interruptHandlers:
          if h.symbol == root or (own >= 0 and (cfg.interruptNesting == "none" or h.priority <= own)): continue
          if h.symbol notin functions and not (h.symbol in cfg.contracts and cfg.contracts[h.symbol].maxStackBytes >= 0):
            summary.findings.add finding("MISSING_STACK_EVIDENCE", "unverified", "interrupt handler " & h.symbol &
              " has no analyzed body or declared maxStackBytes", (fn.file, fn.first), @[root, h.symbol])
            unknown = true
            continue
          let handler = stackUsage(h.symbol)
          summary.findings.add handler.findings
          for assumption in handler.assumptions: summary.assumptions.incl assumption
          for frame in handler.frames:
            if frame notin frames.getElems: frames.add frame
          if handler.unknown: unknown = true
          else: candidates.add (h.symbol, h.priority, handler.bytes + cfg.interruptEntryBytes)
        if not unknown:
          if cfg.interruptNesting == "none":
            for c in candidates:
              if c.bytes > interruptBytes: (interruptBytes, interruptChain) = (c.bytes, @[c.symbol])
          else:
            # heaviest chain of strictly rising priorities (priorities are small integers)
            candidates.sort(proc (a, b: auto): int = cmp(a.priority, b.priority))
            var best = newSeq[tuple[bytes: BiggestInt, chain: seq[string]]](candidates.len)
            for i, c in candidates:
              best[i] = (c.bytes, @[c.symbol])
              for j in 0 ..< i:
                if candidates[j].priority < c.priority and best[j].bytes + c.bytes > best[i].bytes:
                  best[i] = (best[j].bytes + c.bytes, best[j].chain & @[c.symbol])
              if best[i].bytes > interruptBytes: (interruptBytes, interruptChain) = best[i]
      summary.unverified = summary.unverified or unknown
      let total = usage.bytes + interruptBytes
      stackEvidence = %*{"maxStackBytes": limit, "upperBound": (if unknown: newJNull() else: %total),
        "callChain": usage.chain, "frames": frames, "assumptions": ordered(usage.assumptions), "unit": "bytes",
        "interrupts": (if cfg.interruptNesting.len == 0: newJNull() else: %*{"nesting": cfg.interruptNesting,
          "entryBytes": cfg.interruptEntryBytes, "source": cfg.interruptOrigin,
          "preemptionBytes": (if unknown: newJNull() else: %interruptBytes), "preemptionChain": interruptChain})}
      if not unknown and total > limit:
        summary.violation = true
        summary.findings.add finding("STACK_LIMIT_EXCEEDED", "violation", "worst-case stack " & $total &
          " bytes (" & $usage.bytes & " own, " & $interruptBytes & " for interrupts) exceeds the profile's maxStackBytes of " &
          $limit, (fn.file, fn.first), usage.chain & interruptChain)
    var timingEvidence = newJNull()
    if check.profile in cfg.timeBudgets:
      # A function's execution time limit is established only by a static analysis bound for this
      # build, in the limit's own unit. A measurement shows one run, never the worst case.
      let limit = cfg.timeBudgets[check.profile]
      let bounds = cfg.timingBounds.getOrDefault((fn.file, fn.name))
      var used = newJArray()
      var best = -1.BiggestInt
      var bestSource = ""
      var reasons: seq[string]
      for bound in bounds:
        used.add %*{"value": bound.value, "unit": bound.unit, "method": bound.methodKind, "tool": bound.tool,
          "source": bound.origin, "stale": (if bound.stale.len > 0: %bound.stale else: newJNull())}
        if bound.methodKind != "static-analysis": reasons.add "a measurement is not an upper bound"
        elif bound.stale.len > 0: reasons.add bound.stale
        elif bound.unit != limit.unit: reasons.add "the bound is in " & bound.unit & ", the limit in " & limit.unit
        elif best < 0 or bound.value < best:
          best = bound.value
          bestSource = bound.assumption
      let site: Site = (fn.file, fn.first)
      if best >= 0:
        summary.assumptions.incl bestSource
        if best > limit.value:
          summary.violation = true
          summary.findings.add finding("EXECUTION_TIME_EXCEEDED", "violation", "execution time bound " & $best & " " &
            limit.unit & " exceeds the profile's maxExecutionTime of " & $limit.value & " " & limit.unit, site, @[root])
      else:
        summary.unverified = true
        let code = if bounds.len == 0: "MISSING_TIMING_EVIDENCE"
                   elif "a measurement is not an upper bound" in reasons and reasons.len == bounds.len and
                        bounds.allIt(it.methodKind == "measurement"): "MEASUREMENT_IS_NOT_A_BOUND"
                   else: "UNKNOWN_EXECUTION_TIME"
        summary.findings.add finding(code, "unverified", (if bounds.len == 0:
          "no timing evidence for " & fn.name & " in " & fn.file else: "no usable upper bound: " & reasons.join("; ")),
          site, @[root])
      timingEvidence = %*{"maxExecutionTime": {"value": limit.value, "unit": limit.unit},
        "upperBound": (if best >= 0: %*{"value": best, "unit": limit.unit} else: newJNull()), "evidence": used}
    var depthEvidence = newJNull()
    if check.profile in cfg.depthLimits:
      let depth = callDepth(root)
      let limit = cfg.depthLimits[check.profile]
      summary.findings.add depth.findings
      summary.unverified = summary.unverified or depth.unknown
      for assumption in depth.assumptions: summary.assumptions.incl assumption
      depthEvidence = %*{"requiredMaximum": limit, "upperBound": (if depth.unknown: newJNull() else: %depth.maximum),
        "callChain": depth.chain, "assumptions": ordered(depth.assumptions), "unit": "source-call-frames"}
      if not depth.unknown and depth.maximum > limit:
        summary.violation = true
        summary.findings.add finding("CALL_DEPTH_LIMIT", "violation", "source call depth " & $depth.maximum & " exceeds required " & $limit,
          depth.site, depth.chain)
    var status = "verified"
    if summary.assumptions.len > 0: status = "conditional"
    if summary.unverified: status = "unverified"
    for effect in forbidden:
      if effect in summary.effects:
        summary.violation = true
        let witness = summary.witnesses[effect]
        summary.findings.add finding("FORBIDDEN_EFFECT", "violation",
          "profile '" & check.profile & "' forbids possible source effect '" & effect & "' in this call closure",
          witness.site, witness.chain)
    if context.len > 0:
      for item in summary.findings.mitems: item["executionContext"] = %context
    if summary.violation: status = "violation"
    var obligationAccepted = status in ["verified", "conditional"]
    for assumption in ordered(summary.assumptions):
      if assumption notin cfg.accepted:
        obligationAccepted = false
        summary.findings.add finding("UNACCEPTED_ASSUMPTION", "conditional",
          "external assumption is not accepted by the project: " & assumption,
          (fn.file, fn.first), @[root])
    if not obligationAccepted: accepted = false
    if status == "violation": overall = "violation"
    elif overall != "violation" and status == "unverified": overall = "unverified"
    elif overall == "verified" and status == "conditional": overall = "conditional"
    for item in summary.findings: allFindings.add item
    obligations.add %*{"file": fn.file, "function": fn.name, "symbol": root,
      "firstLine": fn.first, "lastLine": fn.last, "profile": check.profile,
      "forbid": forbidden, "executionContext": context, "protocolScope": protocolScope, "protocols": selectedProtocols, "effects": ordered(summary.effects),
      "status": status, "accepted": obligationAccepted, "callDepth": depthEvidence, "stackUsage": stackEvidence, "executionTime": timingEvidence, "borrowCapacity": capacityEvidence, "accessCapacity": accessCapacityEvidence, "accessAlignment": accessAlignmentEvidence, "sourceMemoryAccess": checkMemory, "sourceAccesses": sourceAccessEvidence, "pointerFormations": pointerFormationEvidence, "borrowAlignment": alignmentEvidence, "borrowRegion": regionEvidence, "mmioAccesses": mmioEvidence, "resourceLimits": resourceEvidence,
      "assumptions": ordered(summary.assumptions), "findings": summary.findings}
  var inputs = newJArray()
  var paths: seq[string]
  for path in inputHashes.keys: paths.add path
  paths.sort()
  for path in paths: inputs.add %*{"path": path, "sha1": inputHashes[path]}
  var contracts = newJArray()
  var contractSymbols: seq[string]
  for symbol in cfg.contracts.keys: contractSymbols.add symbol
  contractSymbols.sort()
  for symbol in contractSymbols:
    let contract = cfg.contracts[symbol]
    contracts.add %*{"symbol": symbol, "effects": contract.effects,
      "assumption": contract.assumption, "package": contract.package,
      "versionDeclared": contract.version, "source": contract.origin,
      "preservesProtocols": contract.preservesProtocols, "accessesDeclared": contract.accessesDeclared,
      "returnPointer": (if contract.returnArgument > 0: %*{"argument": contract.returnArgument, "byteOffset": contract.returnOffset, "nullable": contract.returnNullable} else: newJNull()),
      "allocates": (if contract.allocates: %*{"sizeArgument": contract.allocSizeArgument,
        "region": (if contract.allocRegion.len > 0: %contract.allocRegion else: newJNull()),
        "capacity": (if contract.allocCapacity > 0: %contract.allocCapacity else: newJNull()),
        "countArgument": (if contract.allocCountArgument > 0: %contract.allocCountArgument else: newJNull()),
        "alignment": contract.allocAlignment, "nullable": contract.allocNullable,
        "releasedBy": contract.allocReleasedBy} else: newJNull()),
      "accesses": contract.accesses, "contextsDeclared": contract.contextsDeclared, "contexts": contract.contexts,
      "implementationAvailable": symbol in functions, "maxCallDepth": (if contract.maxCallDepth > 0: %contract.maxCallDepth else: newJNull()),
      "barrier": contract.barrier}
  var protocols = newJArray()
  var protocolIds: seq[string]
  for id in cfg.protocols.keys: protocolIds.add id
  protocolIds.sort()
  for id in protocolIds:
    let spec = cfg.protocols[id]
    protocols.add %*{"id": id, "package": spec.package, "versionDeclared": spec.version,
      "source": spec.origin, "initial": spec.initial, "terminal": spec.terminal, "forbidWhile": spec.forbidWhile}
  var capabilities = @[effectCapability, "source-recursion.c.v1", "source-call-depth.c.v1"]
  if cfg.targetBindings.len > 0: capabilities.add "source-contract-target.v1"
  if cfg.compilationBindings.len > 0: capabilities.add "source-contract-compilation.v1"
  if cfg.artifacts.len > 0: capabilities.add "source-contract-artifacts.v1"
  if cfg.boundaries.len > 0: capabilities.add "source-function-boundaries.c.v1"
  if cfg.marks.len > 0: capabilities.add "source-buffer-marks.c.v1"
  if cfg.regions.len > 0: capabilities.add "source-memory-regions.c.v1"
  if cfg.mmioRegisters.len > 0: capabilities.add "source-mmio-registers.c.v1"
  var limits = cfg.heapBudgets.len > 0
  for contract in cfg.contracts.values:
    if contract.allocCapacity > 0: limits = true
  if limits: capabilities.add "source-allocation-limits.c.v1"
  if cfg.stackBudgets.len > 0: capabilities.add "source-stack-usage.c.v1"
  if cfg.timeBudgets.len > 0: capabilities.add "external-execution-time.v1"
  for boundaries in cfg.boundaries.values:
    if boundaries.len > 1 and "source-boundary-composition.c.v1" notin capabilities:
      capabilities.add "source-boundary-composition.c.v1"
    for boundary in boundaries:
      if boundary.outcomes.len > 0 and "source-boundary-results.c.v1" notin capabilities:
        capabilities.add "source-boundary-results.c.v1"
  if cfg.memoryProfiles.len > 0:
    capabilities.add "source-memory-access.c.v1"
    capabilities.add "source-pointer-formation.c.v1"
    capabilities.add "source-pointer-difference-gate.c.v1"
    capabilities.add "source-pointer-comparison-gate.c.v1"
    capabilities.add "source-pointer-value-lifetime.c.v1"
    capabilities.add "source-pointer-return-lifetime.c.v1"
    capabilities.add "source-null-pointer-tracking.c.v1"
    capabilities.add "source-short-circuit-access.c.v1"
    capabilities.add "source-conditional-access.c.v1"
    capabilities.add "source-conditional-calls.c.v1"
    capabilities.add "source-short-circuit-calls.c.v1"
  if cfg.requiresMemoryAccess or cfg.protocolProfiles.len > 0 or cfg.memoryProfiles.len > 0:
    capabilities.add "source-identity-pointer-cast.c.v1"
    capabilities.add "source-pointer-updates.c.v1"
    capabilities.add "source-visible-pointer-results.c.v1"
    capabilities.add "source-conditional-pointer.c.v1"
    capabilities.add "source-conditional-pointer-calls.c.v1"
    capabilities.add "source-pointer-result-conditions.c.v1"
    capabilities.add "source-pointer-result-read.c.v1"
    capabilities.add "source-pointer-result-subscript.c.v1"
    capabilities.add "source-pointer-result-write.c.v1"
    capabilities.add "source-pointer-result-arithmetic.c.v1"
    capabilities.add "source-pointer-result-address.c.v1"
    capabilities.add "source-pointer-result-null-comparison.c.v1"
    capabilities.add "source-commuted-pointer.c.v1"
    capabilities.add "source-return-pointer-contract.c.v1"
    capabilities.add "source-return-pointer-offset.c.v1"
    capabilities.add "source-nullable-pointer-contract.c.v1"
    capabilities.add "source-fixed-type-query.c.v1"
    capabilities.add "source-pointer-bindings.c.v1"
    capabilities.add "source-do-while.c.v1"
    capabilities.add "source-for-loops.c.v1"
    capabilities.add "source-unsigned-updates.c.v1"
    capabilities.add "source-signed-for-counters.c.v1"
    capabilities.add "source-unsigned-compound.c.v1"
    capabilities.add "source-integer-parameter-storage.c.v1"
  for contract in cfg.contracts.values:
    if contract.allocates:
      capabilities.add "source-allocation-contract.c.v1"
      break
  if cfg.requiresAccessAlignment: capabilities.add "source-access-alignment.c.v1"
  if cfg.requiresAccessCapacity: capabilities.add "source-access-capacity.c.v1"
  if cfg.profileContexts.len > 0: capabilities.add "source-contexts.c.v1"
  if cfg.protocolProfiles.len > 0:
    capabilities.add "source-protocols.c.v1"
    capabilities.add "source-storage-permissions.c.v1"
    capabilities.add "source-scalar-arguments.c.v1"
    capabilities.add "source-protocol-blocks.c.v1"
  for spec in cfg.protocols.values:
    if spec.forbidWhile.len > 0 and "source-state-effects.c.v1" notin capabilities:
      capabilities.add "source-state-effects.c.v1"
    for operation in spec.operations:
      if operation.outcomes.len > 0 and "source-protocol-results.c.v1" notin capabilities:
        capabilities.add "source-protocol-results.c.v1"
      for op in variants(operation):
        if op.alignment > 0 and "source-borrow-alignment.c.v1" notin capabilities:
          capabilities.add "source-borrow-alignment.c.v1"
        if op.minBytes > 0 and "source-borrow-capacity.c.v1" notin capabilities:
          capabilities.add "source-borrow-capacity.c.v1"
        if op.borrowArgument > 0 and "source-async-borrows.c.v1" notin capabilities:
          capabilities.add "source-async-borrows.c.v1"
  var artifactEvidence = newJArray()
  for artifact in cfg.artifacts:
    artifactEvidence.add %*{"path": artifact.path, "role": artifact.role,
      "package": artifact.package, "versionDeclared": artifact.version, "source": artifact.source,
      "requiredSha1": artifact.sha1, "observedSha1": inputHashes[artifact.path],
      "parsed": artifact.path in parsedInputs}
  var compilationEvidence = newJArray()
  for binding in cfg.compilationBindings:
    compilationEvidence.add %*{"package": binding.package, "versionDeclared": binding.version,
      "source": binding.source, "requiredArguments": binding.arguments,
      "requiredClangVersion": binding.clangVersion, "requiredDirectory": binding.directory,
      "checkedSources": cfg.sources}
  var targetEvidence = newJArray()
  for binding in cfg.targetBindings:
    targetEvidence.add %*{"package": binding.package, "versionDeclared": binding.version,
      "source": binding.source, "requiredTriple": binding.triple,
      "requiredPointerWidth": binding.pointerWidth, "unit": "bits", "checkedSources": cfg.sources}
  result.report = %*{"schemaVersion": 1, "kind": "safety-result", "project": cfg.id,
    "tool": "kenbi", "toolVersion": "0.1.0", "capability": effectCapability, "capabilities": capabilities,
    "clangVersion": clangVersion, "workingDirectory": getCurrentDir(),
    "phase": "source", "status": overall, "accepted": accepted,
    "obligations": obligations, "findings": allFindings, "inputs": inputs,
    "compilation": compilation, "executionContexts": cfg.contexts, "contracts": contracts, "protocolSpecifications": protocols, "functionBoundaries": cfg.boundaries, "contractArtifacts": artifactEvidence, "contractCompilation": compilationEvidence, "contractTargets": targetEvidence,
    "depthContractAssumptions": ordered(depthContractAssumptions), "depthContractEvidence": depthContractEvidence, "toolSha1": $secureHash(readFile(getAppFilename()))}
  # Which mark definitions applied, and from which document, so a reader can tell what a mark
  # name meant for this run.
  var markDefinitions = newJArray()
  var markIds: seq[string]
  for id in cfg.marks.keys: markIds.add id
  markIds.sort()
  for id in markIds:
    let spec = cfg.marks[id]
    markDefinitions.add %*{"id": id, "source": spec.origin, "clearedBy": spec.clearedBy, "forbids": spec.forbids}
  result.report["markDefinitions"] = markDefinitions
  # Region definitions and the declared placement of automatic storage, with their sources.
  var regionDefinitions = newJArray()
  var regionIds: seq[string]
  for id in cfg.regions.keys: regionIds.add id
  regionIds.sort()
  for id in regionIds:
    regionDefinitions.add %*{"id": id, "source": cfg.regions[id].origin, "properties": cfg.regions[id].properties}
  result.report["regionDefinitions"] = regionDefinitions
  var registers = newJArray()
  for r in cfg.mmioRegisters:
    registers.add %*{"id": r.id, "address": r.address, "width": r.width, "access": r.access,
      "reservedMask": r.reservedMask, "reservedWrite": (if r.reservedWrite.len > 0: %r.reservedWrite else: newJNull()),
      "reservedReadsAs": (if r.reservedReadsZero: %"zero" else: newJNull()),
      "writeOneToClear": r.writeOneToClear, "readToClear": r.readToClear,
      "requiresBarrier": (if r.requiresBarrier.len > 0: %r.requiresBarrier else: newJNull()),
      "assumption": r.assumption, "source": r.origin}
  var blocks = newJArray()
  for b in cfg.mmioBlocks: blocks.add %*{"id": b.id, "base": b.base, "size": b.size, "source": b.origin}
  result.report["mmio"] = %*{"registers": registers, "blocks": blocks}
  result.report["placement"] = %*{"automatic": (if cfg.automaticRegion.len > 0:
    %*{"region": cfg.automaticRegion, "source": cfg.automaticRegionOrigin} else: newJNull())}
  result.exitCode = if accepted: 0 else: 1

proc safetyMain*(path: string, jsonOutput: bool): int =
  try:
    let outcome = checkSafety(loadSafetyConfig(path))
    if jsonOutput: echo outcome.report.pretty
    else:
      echo "kenbi source effects: ", outcome.report["status"].getStr,
        " (accepted: ", outcome.report["accepted"].getBool, ")"
      for item in outcome.report["findings"]:
        echo item["file"].getStr, ":", item["line"].getInt, ": ",
          item["message"].getStr, " [", item["code"].getStr, "]"
    result = outcome.exitCode
  except CatchableError as e:
    if jsonOutput:
      echo (%*{"schemaVersion": 1, "kind": "safety-result", "phase": "source",
        "status": "unverified", "accepted": false, "findings": [
          {"code": "SAFETY_INPUT_ERROR", "message": e.msg}]}).pretty
    else: stderr.writeLine "kenbi: " & e.msg & " [SAFETY_INPUT_ERROR]"
    result = 2
