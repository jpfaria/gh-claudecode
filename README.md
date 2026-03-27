# gh-claudecode

Automated GitHub issue refinement and resolution using Claude Code.

Two independent agents that work together to automate the issue lifecycle:

1. **Refiner** — Monitors new issues, interacts with humans to clarify requirements, fills a mandatory checklist, and marks issues as `ready`
2. **Solver** — Picks up `approved` issues, creates worktrees/branches, implements solutions using Claude Code, and opens PRs

## Requirements

- [GitHub CLI (`gh`)](https://cli.github.com/)
- [Claude Code (`claude`)](https://docs.anthropic.com/en/docs/claude-code)
- `git`
- `jq`

## Quick Start

### 1. Install dependencies

**macOS:**
```bash
brew install gh jq git
npm install -g @anthropic-ai/claude-code
```

**Ubuntu/Debian:**
```bash
sudo apt install jq git
# gh: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list > /dev/null
sudo apt update && sudo apt install gh
# claude code
npm install -g @anthropic-ai/claude-code
```

### 2. Authenticate

**GitHub CLI:**
```bash
# Interactive login (opens browser)
gh auth login

# Verify authentication
gh auth status

# Required scopes: repo, project, read:org
# If scopes are missing:
gh auth refresh -s repo,project,read:org
```

**Claude Code:**
```bash
# Interactive login (opens browser for Anthropic account)
claude

# Or set API key directly
export ANTHROPIC_API_KEY="sk-ant-..."
```

### 3. Clone this repo

```bash
git clone git@github.com:jpfaria/gh-claudecode.git
cd gh-claudecode
```

### 4. Configure

```bash
cp config.example .env
vim .env
```

Set at minimum:
```bash
REPO="owner/repo"   # e.g. jpfaria/OpenRig
```

### 5. Prepare the target repository

Run the setup script to create all required labels and verify the project board:

```bash
./setup.sh --repo owner/repo
```

This will:
- Create the 6 required labels (`refining`, `ready`, `approved`, `in-progress`, `done`, `failed`)
- Verify that `gh` and `claude` are authenticated
- Verify the target repo exists and is accessible

**If you want to do it manually:**

```bash
# Create labels
gh label create refining     --repo owner/repo --color 0E8A16 --description "Refiner is interacting with human"
gh label create ready        --repo owner/repo --color 1D76DB --description "Checklist complete, awaiting approval"
gh label create approved     --repo owner/repo --color 5319E7 --description "Approved for implementation"
gh label create in-progress  --repo owner/repo --color FBCA04 --description "Solver is working on it"
gh label create done         --repo owner/repo --color 0E8A16 --description "PR created"
gh label create failed       --repo owner/repo --color D93F0B --description "Solver timed out or failed"
```

### 6. Run

**Terminal 1 — Refiner:**
```bash
./refiner.sh --repo owner/repo
```

**Terminal 2 — Solver:**
```bash
./solver.sh --repo owner/repo
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
./solver.sh --repo jpfaria/OpenRig --repo-dir /path/to/local/OpenRig
./solver.sh --repo jpfaria/OpenRig --repo-dir /path/to/local/OpenRig --interval 300 --timeout 7200
```

If `--repo-dir` is not provided, the solver clones the repo into `worktrees/_repo/`.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `REPO` | — | GitHub repo (`owner/repo`) |
| `REPO_DIR` | — | Path to local repo (avoids cloning) |
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

| Label | Color | Meaning | Set by |
|-------|-------|---------|--------|
| *(none)* | — | New issue, needs refinement | Human |
| `refining` | 🟢 `#0E8A16` | Refiner is interacting | Refiner |
| `ready` | 🔵 `#1D76DB` | Checklist complete | Refiner |
| `approved` | 🟣 `#5319E7` | Approved for implementation | Human |
| `in-progress` | 🟡 `#FBCA04` | Solver working | Solver |
| `done` | 🟢 `#0E8A16` | PR created | Solver |
| `failed` | 🔴 `#D93F0B` | Timeout or error | Solver |

## Issue Checklist

The Refiner ensures every issue has:

- **Problem described** — clear description of the bug or need
- **Proposed solution** — how to solve it
- **Affected files** — which files/modules are impacted
- **Acceptance criteria** — how to verify it works
- **Type** — bug / feature / enhancement
- **Complexity estimate** — low / medium / high

## Troubleshooting

### `gh` authentication issues

```bash
# Check current auth status
gh auth status

# Re-authenticate
gh auth login

# Check required scopes
gh auth status -t
# Must include: repo, project, read:org
```

### `claude` not responding

```bash
# Check if claude is available
claude --version

# Test with a simple prompt
echo "Hello" | claude -p
```

### Labels already exist

The setup script and refiner both handle this gracefully — existing labels are skipped.

### Solver can't create worktree

```bash
# Check for stale worktrees
git worktree list
git worktree prune
```

## Architecture

See [docs/2026-03-26-design.md](docs/2026-03-26-design.md) for the full design spec.

## License

MIT
