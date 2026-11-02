# Security policy

kenbi is a checker: its job is to say when C/C++ code is not memory-safe within the checks it
runs. The most serious bug it can have is therefore a **false GREEN** — code that kenbi passes
although it contains a defect of a class kenbi claims to check. Those are treated as security
issues, alongside vulnerabilities in kenbi itself.

## Supported versions

kenbi is in early development. Only the latest release (currently 0.1.x) and the default branch
receive fixes.

## What to report

- **A false GREEN.** A file, function or `--safety` project that kenbi reports clean (or
  `verified`) although it contains a defect in a class that was checked: for example a double
  free, use after free or leak under ownership checking, an unchecked index under `@spatial`, an
  unguarded access under `@threadsafe`. The scope of a GREEN is described in
  [README.md](README.md#what-a-green-does-and-does-not-promise). A defect outside it — an axis
  that was off, code behind a trusted contract or `@unsafe`, code the build excluded — is not a
  false GREEN, but a report is still welcome if the documentation made it look like one.
- **A vulnerability in kenbi or its MCP server** (`mcp/`): for example a crash or hang on some
  input, or a way for the arguments of a tool call to do more than run the analysis.

Note that kenbi analyses code by handing its compile flags to libclang. Flags come from
`compile_commands.json`, from arguments after `--`, and from the MCP server's `clangArgs`. They
are trusted the way a compiler command line is trusted, so only analyse a project whose build
configuration you would also be willing to compile.

## How to report

Please report privately through GitHub's private vulnerability reporting: the **Security** tab of
the repository, then **Report a vulnerability**. Include:

- the kenbi version (`kenbi --version`, which also prints the libclang it loaded),
- a minimal source file, the command line or `compile_commands.json` entry, and the output,
- for a false GREEN, the defect and the line where it occurs.

A false GREEN that is already public, or that you found in a test corpus, can also be opened as
an ordinary issue. Reproductions are used as static-analysis inputs only; there is no need to
supply a program that actually triggers the defect when run.

## What happens next

You will get an acknowledgement as soon as the report has been read. A confirmed false GREEN is
fixed in the engine with a regression test under `tests/`, never by changing what a test expects,
and the fix is noted in [CHANGELOG.md](CHANGELOG.md). You will be credited unless you ask not to
be.
