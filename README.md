# gh-claudecode

Automated GitHub issue refinement and resolution using Claude Code.

Two independent agents that work together to automate the issue lifecycle:

1. **Refiner** — Monitors new issues, interacts with humans to clarify requirements, fills a mandatory checklist, and marks issues as ready
2. **Solver** — Picks up approved issues, creates worktrees/branches, implements solutions using Claude Code, and opens PRs

## Requirements

- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated
- [Claude Code (`claude`)](https://docs.anthropic.com/en/docs/claude-code) — authenticated
- `git`
- `jq`

## Setup

1. Clone the repo:
```bash
git clone git@github.com:jpfaria/gh-claudecode.git
cd gh-claudecode
```

2. Copy and edit configuration:
```bash
cp config.example .env
vim .env
```

3. Create the **Approved** column in your GitHub Project Board (between Ready and In Progress)

## Usage

### Refiner

Watches for new issues and interacts with humans to fill the checklist:

```bash
./refiner.sh --repo jpfaria/OpenRig --project 1
./refiner.sh --repo jpfaria/OpenRig --project 1 --interval 60
./refiner.sh --repo jpfaria/OpenRig --project 1 --model claude-opus-4-6
```

### Solver

Watches for approved issues and implements them:

```bash
./solver.sh --repo jpfaria/OpenRig --project 1
./solver.sh --repo jpfaria/OpenRig --project 1 --interval 300
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `REPO` | — | GitHub repo (`owner/repo`) |
| `PROJECT_NUMBER` | — | GitHub Project number |
| `REFINER_INTERVAL` | `300` | Refiner polling interval (seconds) |
| `SOLVER_INTERVAL` | `600` | Solver polling interval (seconds) |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Claude model |

## Project Board Columns

| Column | Managed by | Meaning |
|--------|-----------|---------|
| **Todo** | Human | Issue created |
| **Ready** | Refiner | Checklist complete |
| **Approved** | Human | Approved for implementation |
| **In Progress** | Solver | Being implemented |
| **Done** | Solver | PR created |

## Issue Checklist

The Refiner ensures every issue has:

- **Problem described** — clear description of the bug or need
- **Proposed solution** — how to solve it
- **Affected files** — which files/modules are impacted
- **Acceptance criteria** — how to verify it works
- **Type** — bug / feature / enhancement
- **Complexity estimate** — low / medium / high

## Architecture

See [docs/2026-03-26-design.md](docs/2026-03-26-design.md) for the full design spec.

## License

MIT
