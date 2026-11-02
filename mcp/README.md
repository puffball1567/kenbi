# kenbi-mcp

An [MCP](https://modelcontextprotocol.io) server that exposes the **kenbi**
deterministic memory-safety checker as a callable tool, so an agent can verify
annotated C/C++ *while it writes it*.

The agent writes annotated C/C++, calls `check_memory_safety`, and fixes until
kenbi reports no findings. The deterministic checker stays the judge: annotations are claims it
verifies against the implementation, which catches mistakes (and LLM
hallucinations) a comment alone would hide.

## Loose coupling

This server is a thin wrapper that **spawns the built `kenbi` binary** and
parses its stable `--format=json` output. It imports no kenbi source. The core
checker (CLI, `nimble build`, the GitHub Action under `integrations/ci/`) has
zero dependency on this directory — people who only want the CI/CD checker can
ignore `mcp/` entirely; no Node or `npm install` required.

## Trust boundary

This server generates nothing for your code: `check_memory_safety` returns kenbi's
findings and nothing else, and `explain_finding` returns fixed worked examples whose every
state is checked against kenbi. Annotation *suggestions* and fix *proposals* for your code
are intentionally **not** here: writing them is the agent's job, and kenbi then checks what
the agent wrote, so the verdict stays deterministic. The `kenbi://annotations` resource is
reference documentation, not a suggestion engine.

## Tools

- **`check_memory_safety`** — run kenbi over C/C++ files and return its findings.
  - `files: string[]` — source paths (`.c/.cc/.cpp/.cxx`).
  - `compileCommands?: string` — path to a `compile_commands.json` (auto-discovered upward if omitted).
  - `clangArgs?: string[]` — extra clang args (e.g. `["-Iinclude"]`), passed after `--`.
  - `cwd?: string` — directory to resolve relative paths against, so results don't depend on where the client launched the server.
  - `timeoutMs?: number` — hard wall-clock limit; a runaway analysis is killed, not left hanging (default 60000, or `$KENBI_TIMEOUT_MS`).

  The result is a text summary followed by kenbi's JSON document. The summary always
  states the scope of the result, with or without findings, because an agent may read
  only the summary:
  - which checks ran (ownership, bounds, locks, initialisation, tagged unions) and, where
    a check covered only some functions, which ones it did not cover;
  - how many adopted functions are `verified`, the functions whose contracts the result
    rests on without having analysed them, and every `@unsafe` that suppressed a finding;
  - that code the preprocessor excluded was not analysed.

  A result without findings is reported as "no findings from the checks that ran", never
  as "clean" or "safe".

- **`explain_finding`** — for a finding code (`"LEAK"`, `"WRONG_DEALLOCATOR"`) or a CWE id
  (`"CWE-415"`), return a worked example in three states: A what triggers it, B why a
  half-fix still fails, C the fix and the contract it declares. The examples come from the
  [three-state corpus](../demo/README_three_state.md); for a code it does not cover, the tool
  lists the codes it does.
  - `code: string` — a kenbi finding code or a CWE id.

## Resources

- **`kenbi://annotations`** — the annotation reference (markdown): how to write
  the `@`-directives the checker verifies.
- **`kenbi://patterns`** — kenbi-verified safe C/C++ idioms (markdown): the canonical
  shapes kenbi declares GREEN, paired with the unsafe shapes it rejects and why, per
  bug class (double-free / use-after-free / leak / non-heap / interior / cross-function
  ownership). Grounding for writing or fixing C/C++ that passes the checker; distilled
  from the repo's three-state Juliet demonstration (`demo/juliet*`).

## Build & run

Requires Node ≥ 22 and a built `kenbi` binary.

```bash
# from the repo root: build the checker
nimble build            # or: nim c -d:release -o:kenbi src/kenbi.nim

# build the server
cd mcp
npm install
npm run build
npm test                # end-to-end: drives the server as an MCP client
```

The server locates the checker via `$KENBI_BIN`, then the repo-root `kenbi`
build, then `kenbi` on `PATH`.

## Configure in an MCP client

Clients that read an `mcpServers` JSON config (Claude Desktop and others):

```json
{
  "mcpServers": {
    "kenbi": {
      "command": "node",
      "args": ["/absolute/path/to/kenbi/mcp/dist/index.js"],
      "env": { "KENBI_BIN": "/absolute/path/to/kenbi/kenbi" }
    }
  }
}
```

Claude Code:

```sh
claude mcp add kenbi -e KENBI_BIN=/absolute/path/to/kenbi/kenbi \
  -- node /absolute/path/to/kenbi/mcp/dist/index.js
```
