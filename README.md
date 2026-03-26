# gh-claudecode

Automated GitHub issue refinement and resolution using Claude Code.

Two independent agents that work together to automate the issue lifecycle:

1. **Refiner** — Monitors new issues, interacts with humans to clarify requirements, fills a mandatory checklist, and marks issues as `ready`
2. **Solver** — Picks up `approved` issues, creates worktrees/branches, implements solutions using Claude Code, and opens PRs

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

3. Create the required labels in your target repository:
```bash
gh label create refining --repo owner/repo --color 0E8A16 --description "Refiner is interacting with human"
gh label create ready --repo owner/repo --color 1D76DB --description "Checklist complete, awaiting approval"
gh label create approved --repo owner/repo --color 5319E7 --description "Approved for implementation"
gh label create in-progress --repo owner/repo --color FBCA04 --description "Solver is working on it"
gh label create done --repo owner/repo --color 0E8A16 --description "PR created"
gh label create failed --repo owner/repo --color D93F0B --description "Solver timed out or failed"
```

## Usage

### Refiner

Watches for new issues and interacts with humans to fill the checklist:

```bash
./refiner.sh --repo jpfaria/OpenRig
./refiner.sh --repo jpfaria/OpenRig --interval 60
./refiner.sh --repo jpfaria/OpenRig --model claude-opus-4-6
```

### Solver

Watches for approved issues and implements them:

```bash
./solver.sh --repo jpfaria/OpenRig
./solver.sh --repo jpfaria/OpenRig --interval 300 --timeout 7200
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `REPO` | — | GitHub repo (`owner/repo`) |
| `REFINER_INTERVAL` | `300` | Refiner polling interval (seconds) |
| `SOLVER_INTERVAL` | `600` | Solver polling interval (seconds) |
| `SOLVER_TIMEOUT` | `3600` | Max time for in-progress before failed (seconds) |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Claude model |

## Issue Lifecycle (Labels)

Agents control state via labels. The GitHub Project Board is for human visualization only.

```
(new issue) → refining → ready → approved → in-progress → done
                                     ↓
                                   failed
```

| Label | Meaning | Set by |
|-------|---------|--------|
| *(none)* | New issue, needs refinement | Human |
| `refining` | Refiner is interacting | Refiner |
| `ready` | Checklist complete | Refiner |
| `approved` | Approved for implementation | Human |
| `in-progress` | Solver working | Solver |
| `done` | PR created | Solver |
| `failed` | Timeout or error | Solver |

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
