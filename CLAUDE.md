# gh-claudecode — Context for Claude Code

## What is this

Two shell scripts that automate GitHub issue lifecycle using Claude Code CLI:
- `refiner.sh` — interacts with humans on issues to fill a mandatory checklist
- `solver.sh` — implements approved issues (worktree, branch, code, PR)

## Development Workflow

Same Gitflow as OpenRig:

1. **Issue** on GitHub before any code
2. **Branch** from `develop`: `feature/issue-{N}-*` or `bugfix/issue-{N}-*`
3. **Commits** in English, no Co-Authored-By
4. **PR** to `develop` with `Closes #N`
5. **Merge policy**: bugfix = immediate, feature = review first
6. **Always push** after commit
7. **develop** always ahead of main

## Tech Stack

- Shell (bash)
- `gh` CLI for GitHub API
- `claude` CLI for AI analysis
- `jq` for JSON processing

## Key Files

- `refiner.sh` — polling loop + issue interaction logic
- `solver.sh` — polling loop + implementation logic
- `config.example` — configuration template
- `docs/2026-03-26-design.md` — full design spec
