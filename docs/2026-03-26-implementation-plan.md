# gh-claudecode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two shell scripts (refiner + solver) that automate GitHub issue lifecycle using Claude Code CLI.

**Architecture:** Two independent bash scripts with polling loops. Each script parses CLI args, loads `.env` config, and runs a loop that queries GitHub issues via `gh` CLI, processes them by calling `claude` CLI, and updates labels/comments. No shared state between scripts.

**Tech Stack:** Bash, `gh` CLI, `claude` CLI, `jq`, `git`

---

## File Map

| File | Responsibility |
|------|---------------|
| `refiner.sh` | Polling loop + issue refinement logic (label management, checklist analysis via claude, commenting) |
| `solver.sh` | Polling loop + issue resolution logic (worktree, branch, claude implementation, PR, stale detection) |
| `config.example` | Already exists — configuration template |
| `.env` | User's local config (gitignored) |

---

### Task 1: refiner.sh — argument parsing and config loading

**Files:**
- Create: `refiner.sh`

- [ ] **Step 1: Create refiner.sh with argument parsing and config**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

# Defaults
REPO="${REPO:-}"
REFINER_INTERVAL="${REFINER_INTERVAL:-300}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --interval) REFINER_INTERVAL="$2"; shift 2 ;;
    --model) CLAUDE_MODEL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Error: --repo is required (e.g. --repo owner/repo)"
  exit 1
fi

# Verify dependencies
for cmd in gh claude jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found in PATH"
    exit 1
  fi
done

echo "[refiner] Starting for $REPO (interval: ${REFINER_INTERVAL}s, model: $CLAUDE_MODEL)"
```

- [ ] **Step 2: Test argument parsing**

Run:
```bash
chmod +x refiner.sh
./refiner.sh --repo jpfaria/OpenRig --interval 10
```
Expected: prints `[refiner] Starting for jpfaria/OpenRig (interval: 10s, model: claude-sonnet-4-6)`

Run without --repo:
```bash
./refiner.sh 2>&1
```
Expected: prints `Error: --repo is required`

- [ ] **Step 3: Commit**

```bash
git add refiner.sh
git commit -m "Add refiner.sh with argument parsing and config loading"
git push origin develop
```

---

### Task 2: refiner.sh — polling loop and new issue detection

**Files:**
- Modify: `refiner.sh`

- [ ] **Step 1: Add polling loop and function to find new issues (no labels)**

Append to `refiner.sh` after the startup echo:

```bash
ensure_labels() {
  local repo="$1"
  for label in refining ready approved in-progress done failed; do
    if ! gh label list --repo "$repo" --json name -q ".[].name" | grep -qx "$label"; then
      case "$label" in
        refining)    gh label create "$label" --repo "$repo" --color 0E8A16 --description "Refiner is interacting with human" ;;
        ready)       gh label create "$label" --repo "$repo" --color 1D76DB --description "Checklist complete, awaiting approval" ;;
        approved)    gh label create "$label" --repo "$repo" --color 5319E7 --description "Approved for implementation" ;;
        in-progress) gh label create "$label" --repo "$repo" --color FBCA04 --description "Solver is working on it" ;;
        done)        gh label create "$label" --repo "$repo" --color 0E8A16 --description "PR created" ;;
        failed)      gh label create "$label" --repo "$repo" --color D93F0B --description "Solver timed out or failed" ;;
      esac
      echo "[refiner] Created label: $label"
    fi
  done
}

get_new_issues() {
  gh issue list --repo "$REPO" --state open --json number,title,labels --limit 100 \
    | jq '[.[] | select(.labels | length == 0)]'
}

get_refining_issues() {
  gh issue list --repo "$REPO" --state open --label refining --json number,title --limit 100
}

ensure_labels "$REPO"

while true; do
  echo "[refiner] Polling at $(date -u +%Y-%m-%dT%H:%M:%SZ)..."

  # Process new issues (no labels)
  new_issues=$(get_new_issues)
  new_count=$(echo "$new_issues" | jq 'length')

  if [[ "$new_count" -gt 0 ]]; then
    echo "[refiner] Found $new_count new issue(s)"
    echo "$new_issues" | jq -c '.[]' | while read -r issue; do
      number=$(echo "$issue" | jq -r '.number')
      title=$(echo "$issue" | jq -r '.title')
      echo "[refiner] Processing new issue #$number: $title"
      # TODO: will be filled in Task 3
    done
  fi

  # Process refining issues
  refining_issues=$(get_refining_issues)
  refining_count=$(echo "$refining_issues" | jq 'length')

  if [[ "$refining_count" -gt 0 ]]; then
    echo "[refiner] Found $refining_count issue(s) being refined"
    echo "$refining_issues" | jq -c '.[]' | while read -r issue; do
      number=$(echo "$issue" | jq -r '.number')
      echo "[refiner] Checking issue #$number for human response"
      # TODO: will be filled in Task 4
    done
  fi

  echo "[refiner] Sleeping ${REFINER_INTERVAL}s..."
  sleep "$REFINER_INTERVAL"
done
```

- [ ] **Step 2: Test polling loop**

Run:
```bash
./refiner.sh --repo jpfaria/OpenRig --interval 5
```
Expected: prints polling messages, finds issues with no labels (if any exist), loops every 5s. Ctrl+C to stop.

- [ ] **Step 3: Commit**

```bash
git add refiner.sh
git commit -m "Add refiner polling loop with new and refining issue detection"
git push origin develop
```

---

### Task 3: refiner.sh — initial refinement of new issues

**Files:**
- Modify: `refiner.sh`

- [ ] **Step 1: Add function to start refinement on a new issue**

Add this function before the `while true` loop, and replace the `# TODO: will be filled in Task 3` line:

```bash
CHECKLIST_TEMPLATE='## Refinement Checklist

- [ ] **Problem described** —
- [ ] **Proposed solution** —
- [ ] **Affected files** —
- [ ] **Acceptance criteria** —
- [ ] **Type** —
- [ ] **Complexity estimate** —'

start_refinement() {
  local number="$1"
  local title="$2"

  # Get issue body
  local body
  body=$(gh issue view "$number" --repo "$REPO" --json body -q '.body')

  # Use claude to analyze the issue and generate initial questions
  local prompt="You are a technical project manager analyzing a GitHub issue for a software project.

Issue #$number: $title

Body:
$body

Your job is to fill a checklist by asking the issue creator clarifying questions. The checklist items are:
1. Problem described — clear description of the bug or need
2. Proposed solution — how to solve it
3. Affected files — which files/crates/modules are impacted
4. Acceptance criteria — how to verify the fix/feature works
5. Type — bug / feature / enhancement
6. Complexity estimate — low / medium / high

Based on what's already in the issue, determine which items you can already fill from the existing text, and ask specific questions for the missing ones.

Reply ONLY with the comment text to post on the issue. Be concise and professional. Use markdown. Start with a greeting and explain you're helping refine the issue."

  local response
  response=$(echo "$prompt" | claude --model "$CLAUDE_MODEL" -p 2>/dev/null)

  if [[ -n "$response" ]]; then
    # Add label
    gh issue edit "$number" --repo "$REPO" --add-label "refining"
    # Post comment
    gh issue comment "$number" --repo "$REPO" --body "$response"
    echo "[refiner] Started refinement on issue #$number"
  else
    echo "[refiner] Error: claude returned empty response for issue #$number"
  fi
}
```

Replace the TODO in the new issues loop:
```bash
      start_refinement "$number" "$title"
```

- [ ] **Step 2: Test with a real issue**

Create a test issue:
```bash
gh issue create --repo jpfaria/OpenRig --title "Test: refiner bot" --body "Something is broken"
```

Run refiner:
```bash
./refiner.sh --repo jpfaria/OpenRig --interval 10
```

Expected: Refiner finds the issue, adds `refining` label, posts a comment asking questions.

- [ ] **Step 3: Commit**

```bash
git add refiner.sh
git commit -m "Add initial issue refinement with claude analysis"
git push origin develop
```

---

### Task 4: refiner.sh — continue refinement and checklist completion

**Files:**
- Modify: `refiner.sh`

- [ ] **Step 1: Add function to continue refinement on existing issues**

Add these functions before the `while true` loop, and replace the `# TODO: will be filled in Task 4` line:

```bash
last_comment_is_human() {
  local number="$1"
  local last_author_type
  last_author_type=$(gh issue view "$number" --repo "$REPO" --json comments \
    -q '.comments[-1].authorAssociation // "NONE"')

  # Bot comments have authorAssociation "NONE" or the comment author login contains [bot]
  local last_author
  last_author=$(gh issue view "$number" --repo "$REPO" --json comments \
    -q '.comments[-1].author.login // ""')

  if [[ "$last_author" == *"[bot]"* ]] || [[ "$last_author" == "github-actions" ]]; then
    return 1
  fi

  # If there are no comments, treat as human (the issue body is from human)
  local comment_count
  comment_count=$(gh issue view "$number" --repo "$REPO" --json comments -q '.comments | length')
  if [[ "$comment_count" -eq 0 ]]; then
    return 0
  fi

  # Check if last commenter is NOT the bot (gh cli authenticated user)
  local me
  me=$(gh api user -q '.login')
  if [[ "$last_author" == "$me" ]]; then
    return 1
  fi

  return 0
}

check_checklist_complete() {
  local analysis="$1"
  # Claude returns JSON with filled fields — check if all 6 are present
  echo "$analysis" | grep -q '"checklist_complete": true'
}

continue_refinement() {
  local number="$1"

  # Get full issue context
  local issue_data
  issue_data=$(gh issue view "$number" --repo "$REPO" --json title,body,comments)

  local title body comments
  title=$(echo "$issue_data" | jq -r '.title')
  body=$(echo "$issue_data" | jq -r '.body')
  comments=$(echo "$issue_data" | jq -r '.comments[] | "[\(.author.login)]: \(.body)"' | tail -20)

  local prompt="You are a technical project manager refining a GitHub issue.

Issue #$number: $title

Body:
$body

Recent comments:
$comments

Mandatory checklist to fill:
1. Problem described — clear description of the bug or need
2. Proposed solution — how to solve it
3. Affected files — which files/crates/modules are impacted
4. Acceptance criteria — how to verify the fix/feature works
5. Type — bug / feature / enhancement
6. Complexity estimate — low / medium / high

Analyze the conversation so far. Based on the information provided:

If ALL 6 items can be filled from the conversation, respond with EXACTLY this format:
CHECKLIST_COMPLETE
---
## Refinement Checklist

- [x] **Problem described** — <filled>
- [x] **Proposed solution** — <filled>
- [x] **Affected files** — <filled>
- [x] **Acceptance criteria** — <filled>
- [x] **Type** — <bug|feature|enhancement>
- [x] **Complexity estimate** — <low|medium|high>

If some items are still missing, respond with a comment asking specific questions for the missing items. Be concise. Do NOT include CHECKLIST_COMPLETE."

  local response
  response=$(echo "$prompt" | claude --model "$CLAUDE_MODEL" -p 2>/dev/null)

  if [[ -z "$response" ]]; then
    echo "[refiner] Error: claude returned empty response for issue #$number"
    return
  fi

  if echo "$response" | head -1 | grep -q "CHECKLIST_COMPLETE"; then
    # Extract checklist (everything after ---)
    local checklist
    checklist=$(echo "$response" | sed -n '/^---$/,$ p' | tail -n +2)

    # Update issue body with checklist appended
    local new_body="$body

---
$checklist"
    gh issue edit "$number" --repo "$REPO" --body "$new_body"

    # Swap labels: refining -> ready
    gh issue edit "$number" --repo "$REPO" --remove-label "refining" --add-label "ready"
    gh issue comment "$number" --repo "$REPO" --body "Refinement complete. All checklist items have been filled. This issue is now **ready** for approval."
    echo "[refiner] Issue #$number marked as ready"
  else
    # Post follow-up questions
    gh issue comment "$number" --repo "$REPO" --body "$response"
    echo "[refiner] Posted follow-up questions on issue #$number"
  fi
}
```

Replace the TODO in the refining issues loop:
```bash
      if last_comment_is_human "$number"; then
        continue_refinement "$number"
      else
        echo "[refiner] Skipping issue #$number — waiting for human response"
      fi
```

- [ ] **Step 2: Test full refinement cycle**

Reply to the test issue you created earlier with answers to the bot's questions. Run refiner and verify it:
1. Detects the human reply
2. Analyzes the conversation
3. Either asks more questions or marks as `ready`

- [ ] **Step 3: Commit**

```bash
git add refiner.sh
git commit -m "Add checklist completion logic and ready label transition"
git push origin develop
```

---

### Task 5: solver.sh — argument parsing, config, and polling loop

**Files:**
- Create: `solver.sh`

- [ ] **Step 1: Create solver.sh with argument parsing, config, and polling**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

# Defaults
REPO="${REPO:-}"
SOLVER_INTERVAL="${SOLVER_INTERVAL:-600}"
SOLVER_TIMEOUT="${SOLVER_TIMEOUT:-3600}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
WORKTREE_DIR="${WORKTREE_DIR:-$SCRIPT_DIR/worktrees}"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --interval) SOLVER_INTERVAL="$2"; shift 2 ;;
    --timeout) SOLVER_TIMEOUT="$2"; shift 2 ;;
    --model) CLAUDE_MODEL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Error: --repo is required (e.g. --repo owner/repo)"
  exit 1
fi

for cmd in gh claude jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found in PATH"
    exit 1
  fi
done

mkdir -p "$WORKTREE_DIR"

# Clone or update repo
REPO_DIR="$WORKTREE_DIR/_repo"
if [[ ! -d "$REPO_DIR" ]]; then
  echo "[solver] Cloning $REPO..."
  gh repo clone "$REPO" "$REPO_DIR" 2>/dev/null
else
  echo "[solver] Updating $REPO..."
  git -C "$REPO_DIR" fetch origin 2>/dev/null
  git -C "$REPO_DIR" checkout develop 2>/dev/null || git -C "$REPO_DIR" checkout main 2>/dev/null
  git -C "$REPO_DIR" pull 2>/dev/null
fi

get_approved_issues() {
  gh issue list --repo "$REPO" --state open --label approved --json number,title --limit 100
}

get_in_progress_issues() {
  gh issue list --repo "$REPO" --state open --label in-progress --json number,title,comments --limit 100
}

echo "[solver] Starting for $REPO (interval: ${SOLVER_INTERVAL}s, timeout: ${SOLVER_TIMEOUT}s, model: $CLAUDE_MODEL)"

while true; do
  echo "[solver] Polling at $(date -u +%Y-%m-%dT%H:%M:%SZ)..."

  # Check for stale in-progress issues
  in_progress=$(get_in_progress_issues)
  ip_count=$(echo "$in_progress" | jq 'length')
  if [[ "$ip_count" -gt 0 ]]; then
    echo "[solver] Checking $ip_count in-progress issue(s) for staleness"
    echo "$in_progress" | jq -c '.[]' | while read -r issue; do
      number=$(echo "$issue" | jq -r '.number')
      # TODO: stale detection in Task 6
    done
  fi

  # Process approved issues
  approved=$(get_approved_issues)
  approved_count=$(echo "$approved" | jq 'length')

  if [[ "$approved_count" -gt 0 ]]; then
    echo "[solver] Found $approved_count approved issue(s)"
    # Process only the first one (sequential)
    issue=$(echo "$approved" | jq -c '.[0]')
    number=$(echo "$issue" | jq -r '.number')
    title=$(echo "$issue" | jq -r '.title')
    echo "[solver] Processing issue #$number: $title"
    # TODO: solve issue in Task 7
  fi

  echo "[solver] Sleeping ${SOLVER_INTERVAL}s..."
  sleep "$SOLVER_INTERVAL"
done
```

- [ ] **Step 2: Test solver argument parsing and polling**

```bash
chmod +x solver.sh
./solver.sh --repo jpfaria/OpenRig --interval 5
```
Expected: clones/updates repo, polls for approved and in-progress issues, loops every 5s.

- [ ] **Step 3: Commit**

```bash
git add solver.sh
git commit -m "Add solver.sh with argument parsing, repo clone, and polling loop"
git push origin develop
```

---

### Task 6: solver.sh — stale detection

**Files:**
- Modify: `solver.sh`

- [ ] **Step 1: Add stale detection function**

Add before the `while true` loop, and replace the `# TODO: stale detection in Task 6` line:

```bash
check_stale() {
  local number="$1"

  # Find the solver's start comment timestamp
  local start_comment
  start_comment=$(gh issue view "$number" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | startswith("[solver] Started at"))] | last')

  if [[ -z "$start_comment" ]] || [[ "$start_comment" == "null" ]]; then
    echo "[solver] No start timestamp found for issue #$number, marking as failed"
    gh issue edit "$number" --repo "$REPO" --remove-label "in-progress" --add-label "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] Marked as **failed**: no start timestamp found."
    return
  fi

  local start_time
  start_time=$(echo "$start_comment" | jq -r '.createdAt')
  local start_epoch
  start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" "+%s" 2>/dev/null \
    || date -d "$start_time" "+%s" 2>/dev/null)

  local now_epoch
  now_epoch=$(date "+%s")

  local elapsed=$(( now_epoch - start_epoch ))

  if [[ "$elapsed" -gt "$SOLVER_TIMEOUT" ]]; then
    echo "[solver] Issue #$number is stale (${elapsed}s > ${SOLVER_TIMEOUT}s timeout)"

    # Clean up worktree if exists
    local wt_dir="$WORKTREE_DIR/issue-$number"
    if [[ -d "$wt_dir" ]]; then
      git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
      echo "[solver] Cleaned up worktree for issue #$number"
    fi

    gh issue edit "$number" --repo "$REPO" --remove-label "in-progress" --add-label "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] Marked as **failed**: timed out after ${elapsed}s (limit: ${SOLVER_TIMEOUT}s)."
    echo "[solver] Issue #$number marked as failed (timeout)"
  fi
}
```

Replace the TODO:
```bash
      check_stale "$number"
```

- [ ] **Step 2: Test stale detection**

Manually label an issue as `in-progress` and run solver with a short timeout:
```bash
./solver.sh --repo jpfaria/OpenRig --interval 5 --timeout 1
```
Expected: detects the issue as stale and marks it `failed`.

- [ ] **Step 3: Commit**

```bash
git add solver.sh
git commit -m "Add stale in-progress detection with timeout and cleanup"
git push origin develop
```

---

### Task 7: solver.sh — issue implementation (worktree, claude, PR)

**Files:**
- Modify: `solver.sh`

- [ ] **Step 1: Add solve_issue function**

Add before the `while true` loop, and replace the `# TODO: solve issue in Task 7` line:

```bash
solve_issue() {
  local number="$1"
  local title="$2"

  # Mark as in-progress
  gh issue edit "$number" --repo "$REPO" --remove-label "approved" --add-label "in-progress"
  gh issue comment "$number" --repo "$REPO" --body "[solver] Started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Get issue details
  local issue_data
  issue_data=$(gh issue view "$number" --repo "$REPO" --json title,body,comments)
  local body
  body=$(echo "$issue_data" | jq -r '.body')

  # Determine branch type from checklist
  local issue_type="feature"
  if echo "$body" | grep -qi "Type.*bug"; then
    issue_type="bugfix"
  fi

  # Create slug from title
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40)
  local branch="${issue_type}/issue-${number}-${slug}"

  # Update repo
  git -C "$REPO_DIR" fetch origin 2>/dev/null
  git -C "$REPO_DIR" checkout develop 2>/dev/null || git -C "$REPO_DIR" checkout main 2>/dev/null
  git -C "$REPO_DIR" pull 2>/dev/null

  # Create worktree
  local wt_dir="$WORKTREE_DIR/issue-$number"
  if [[ -d "$wt_dir" ]]; then
    git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
  fi
  git -C "$REPO_DIR" worktree add "$wt_dir" -b "$branch" 2>/dev/null

  echo "[solver] Created worktree at $wt_dir on branch $branch"

  # Build prompt for claude
  local comments
  comments=$(echo "$issue_data" | jq -r '.comments[] | "[\(.author.login)]: \(.body)"' | tail -20)

  local prompt="You are implementing a GitHub issue for a software project.

Repository: $REPO
Issue #$number: $title

Issue body:
$body

Comments:
$comments

Instructions:
1. Read the CLAUDE.md file in the repo root for project context and coding standards
2. Implement the solution described in the issue checklist
3. Follow the project's coding conventions
4. Make sure the code compiles without errors or warnings
5. Commit your changes with a message referencing the issue: 'Closes #$number'
6. Do NOT push — I will handle that"

  # Run claude in the worktree
  local claude_exit=0
  (cd "$wt_dir" && echo "$prompt" | claude --model "$CLAUDE_MODEL" -p) || claude_exit=$?

  if [[ "$claude_exit" -ne 0 ]]; then
    echo "[solver] Claude failed for issue #$number (exit code: $claude_exit)"
    gh issue edit "$number" --repo "$REPO" --remove-label "in-progress" --add-label "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: Claude exited with code $claude_exit"
    git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
    return
  fi

  # Check if there are commits
  local commit_count
  commit_count=$(git -C "$wt_dir" rev-list --count "develop..$branch" 2>/dev/null || echo "0")

  if [[ "$commit_count" -eq 0 ]]; then
    echo "[solver] No commits made for issue #$number"
    gh issue edit "$number" --repo "$REPO" --remove-label "in-progress" --add-label "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: Claude made no commits."
    git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
    return
  fi

  # Push branch
  git -C "$wt_dir" push -u origin "$branch" 2>/dev/null

  # Create PR
  local pr_url
  pr_url=$(gh pr create --repo "$REPO" --head "$branch" --base develop \
    --title "$title" \
    --body "Closes #$number

Automated implementation by gh-claudecode solver." 2>/dev/null)

  echo "[solver] Created PR: $pr_url"

  # Mark as done
  gh issue edit "$number" --repo "$REPO" --remove-label "in-progress" --add-label "done"
  gh issue comment "$number" --repo "$REPO" --body "[solver] **Done**: PR created — $pr_url"

  # Clean up worktree
  git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true

  echo "[solver] Issue #$number completed"
}
```

Replace the TODO:
```bash
    solve_issue "$number" "$title"
```

- [ ] **Step 2: Test full solve cycle**

Create and approve a test issue:
```bash
gh issue create --repo jpfaria/OpenRig --title "Test: add comment to README" --body "Add a line to README.md saying 'Automated test'"
gh issue edit <NUMBER> --repo jpfaria/OpenRig --add-label "approved"
```

Run solver:
```bash
./solver.sh --repo jpfaria/OpenRig --interval 10
```

Expected: solver picks up the issue, creates worktree, runs claude, pushes branch, creates PR, marks done.

- [ ] **Step 3: Commit**

```bash
git add solver.sh
git commit -m "Add issue implementation with worktree, claude, and PR creation"
git push origin develop
```

---

### Task 8: Final testing and cleanup

**Files:**
- Verify: `refiner.sh`, `solver.sh`

- [ ] **Step 1: End-to-end test — full lifecycle**

1. Create a vague issue:
```bash
gh issue create --repo jpfaria/OpenRig --title "Test: end-to-end lifecycle" --body "Fix the thing"
```

2. Start refiner:
```bash
./refiner.sh --repo jpfaria/OpenRig --interval 10
```

3. Wait for refiner to comment, reply with details in the issue comments on GitHub

4. Wait for refiner to mark as `ready`

5. Approve the issue:
```bash
gh issue edit <NUMBER> --repo jpfaria/OpenRig --remove-label "ready" --add-label "approved"
```

6. Start solver:
```bash
./solver.sh --repo jpfaria/OpenRig --interval 10
```

7. Verify: worktree created, branch created, claude ran, PR created, issue marked `done`

- [ ] **Step 2: Clean up test issues**

```bash
gh issue close <NUMBER> --repo jpfaria/OpenRig
```

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "Final cleanup after end-to-end testing"
git push origin develop
```
