// The reference for the configured checks, served as the `kenbi://safety` resource.
export const SAFETY_REFERENCE = `# kenbi configured checks (\`--safety\`) — reference

Some rules of low-level code are not memory safety: an interrupt handler must not allocate or
block, a filesystem must not recurse. kenbi checks them when a project declares them. Use the
\`check_configured_safety\` tool with the project file.

## What is checked
For each function (or block) the project names, kenbi collects every effect the function and
everything it calls MAY perform, and compares it with what the profile forbids.

| effect | meaning |
|---|---|
| \`heap_allocate\` | may allocate heap memory (\`malloc\`, \`calloc\`, \`realloc\`, \`strdup\`, … are known) |
| \`recurse\` | the call graph below it contains a cycle |
| \`block\` | may block |
| \`wait\` | may wait |

## Naming what to check
In the source, above a function definition or a \`{ ... }\` block:

\`\`\`c
// @verify(interrupt)
void uart_irq(void) { ... }
\`\`\`

or in the project file's \`checks\`. A \`@verify\` comment in a file checked without a project is
an error, never ignored.

## The project file
\`\`\`json
{
  "schemaVersion": 1,
  "kind": "project",
  "id": "my_driver",
  "sources": ["driver.c", "helper.c"],
  "clangArgs": ["-I", "include"],
  "contracts": ["board.contracts.json"],
  "profiles": {
    "interrupt": {"forbid": ["heap_allocate", "block", "wait"]},
    "no_recursion": {"forbid": ["recurse"]}
  },
  "checks": [{"file": "driver.c", "function": "uart_irq", "profile": "interrupt"}],
  "acceptedAssumptions": ["board.wait.contract"]
}
\`\`\`
Paths are relative to the file that declares them. Unknown keys, unknown profiles and sources
that do not parse are errors: the run checks nothing rather than something else.

## Contracts: what the sources do not contain
A function with no body among the \`sources\` needs an effect contract, or the obligation is
\`unverified\`:

\`\`\`json
{
  "schemaVersion": 1, "kind": "contracts", "id": "board", "version": "1",
  "functions": [
    {"symbol": "c:@F@board_wait", "effects": ["block", "wait"], "assumption": "board.wait.contract"}
  ]
}
\`\`\`
\`effects: []\` declares that the function performs none of the effects above. The \`assumption\`
id must be listed in the project's \`acceptedAssumptions\`; accept one only when a person has
decided it holds. A contract for a function whose body IS among the sources is checked against
that body (\`CONTRACT_EFFECT_MISMATCH\` if the body may do more).

For \`memcpy\`, \`strlen\` and the other C string functions, and the compiler builtins, add the
shipped package \`contracts/c-library.contracts.json\` to \`contracts\` and accept
\`c-library.string.no-effects\` and \`compiler.builtins.no-effects\`.

## Function pointers
A call through a function-pointer PARAMETER is followed to the functions passed for it on the
call path — by name, through a function that passes the pointer on, or assigned to the
parameter in the body. Write the function's name at the call site and no contract is needed.

A pointer the source does not settle needs a contract on the pointer's own symbol, which the
\`UNRESOLVED_EFFECT_CALL\` finding names:

| pointer | symbol |
|---|---|
| a struct field (\`cfg->read(...)\`) | \`c:@S@config@FI@read\` |
| a parameter of the checked or an exported function | \`c:@F@walk@param:visit\` |

Such a contract covers every function the pointer may hold. It is checked against every
function the sources store in it (\`.read = my_read\`, \`cfg->read = my_read\`): one that may do
more than the contract declares is \`CONTRACT_EFFECT_MISMATCH\`, reported at the store.

## Reading the result
| status | meaning |
|---|---|
| \`verified\` | holds, with nothing taken on declaration |
| \`conditional\` | holds if the listed assumptions do |
| \`unverified\` | kenbi could not decide — NOT a pass |
| \`violation\` | the code may do what the profile forbids, or contradicts a contract |

The run is accepted only when every obligation is \`verified\`, or \`conditional\` on assumptions
the project accepts. A \`FORBIDDEN_EFFECT\` means a call path to the effect exists in the
source; it does not mean that path runs.

## What does not resolve a finding
- Declaring a callee free of effects when it is not: the contract is checked against its body.
- Accepting an assumption to make a run pass: \`acceptedAssumptions\` records a person's decision.
- Removing the \`@verify\` comment or the \`checks\` entry.
`;
