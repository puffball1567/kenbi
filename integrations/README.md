# integrations

Drop-in files for using **kenbi** in your own C/C++ project and agent workflow.
Nothing here runs as part of kenbi's own CI — copy what you need into your repo.

## agent/ — LLM / agent guidance

One canonical guide, plus thin wrappers per tool. The principle is the same
everywhere: the deterministic kenbi checker is the verdict; the agent *authors*
annotations and safer code and gives grounded, advisory-only review.

| file | where it goes in your repo | for |
|---|---|---|
| `SKILL.md` | `.claude/skills/kenbi-memory-safety/SKILL.md` | Claude Code (canonical, full) |
| `AGENTS.md` | repo root `AGENTS.md` | Codex-style agents |
| `copilot-instructions.md` | `.github/copilot-instructions.md` | GitHub Copilot |

`SKILL.md` is the source of truth; the others are thin wrappers that point to it,
so there is one place to update when the guidance changes.

## ci/ — continuous integration

| file | where it goes | does |
|---|---|---|
| `kenbi-review.yml` | `.github/workflows/kenbi-review.yml` | builds kenbi and runs it over your C/C++ on every PR |

The deterministic core can **gate** (fail the PR on findings — the default) or
run as a non-blocking **neutral check** (advisory) while you tune annotations.
See the comments in the file. It needs a `compile_commands.json` and kenbi
ownership annotations on the code you want checked.
