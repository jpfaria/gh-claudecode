#!/usr/bin/env bash
set -euo pipefail

# Load .env file if it exists (from script directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

# Load shared library
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Default values
REPO="${REPO:-}"
REPO_DIR="${REPO_DIR:-}"
SOLVER_INTERVAL="${SOLVER_INTERVAL:-600}"
SOLVER_TIMEOUT="${SOLVER_TIMEOUT:-3600}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
WORKTREE_DIR="${WORKTREE_DIR:-$SCRIPT_DIR/worktrees}"

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --interval)
      SOLVER_INTERVAL="$2"
      shift 2
      ;;
    --timeout)
      SOLVER_TIMEOUT="$2"
      shift 2
      ;;
    --model)
      CLAUDE_MODEL="$2"
      shift 2
      ;;
    --repo-dir)
      REPO_DIR="$2"
      shift 2
      ;;
    *)
      echo "[solver] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Validate --repo is provided
if [[ -z "$REPO" ]]; then
  echo "[solver] Error: --repo is required" >&2
  exit 1
fi

# Normalize REPO to owner/repo format
REPO=$(normalize_repo "$REPO")

# Check dependencies
for cmd in gh claude jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[solver] Error: '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Repo setup
# ---------------------------------------------------------------------------

# Use provided repo dir or clone
if [[ -z "$REPO_DIR" ]]; then
  mkdir -p "$WORKTREE_DIR"
  REPO_DIR="$WORKTREE_DIR/_repo"
  if [[ ! -d "$REPO_DIR" ]]; then
    echo "[solver] Cloning $REPO into $REPO_DIR"
    gh repo clone "$REPO" "$REPO_DIR"
  fi
fi

# Worktrees go next to the repo (sibling directory)
WORKTREE_DIR="$(dirname "$REPO_DIR")/$(basename "$REPO_DIR")-worktrees"
mkdir -p "$WORKTREE_DIR"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "[solver] Error: $REPO_DIR is not a git repository" >&2
  exit 1
fi

echo "[solver] Using repo at $REPO_DIR"
git -C "$REPO_DIR" fetch origin 2>/dev/null

# Checkout develop if it exists, otherwise fall back to main
if git -C "$REPO_DIR" rev-parse --verify origin/develop &>/dev/null; then
  git -C "$REPO_DIR" checkout develop 2>/dev/null
  git -C "$REPO_DIR" pull origin develop 2>/dev/null
else
  git -C "$REPO_DIR" checkout main 2>/dev/null
  git -C "$REPO_DIR" pull origin main 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Lock mechanism
# ---------------------------------------------------------------------------

LOCK_DIR="$SCRIPT_DIR/.locks"
mkdir -p "$LOCK_DIR"

acquire_lock() {
  local number="$1"
  mkdir "$LOCK_DIR/solver-issue-$number" 2>/dev/null && return 0
  return 1
}

release_lock() {
  local number="$1"
  rmdir "$LOCK_DIR/solver-issue-$number" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

get_approved_issues() {
  get_issues_by_board_status_with_comments "Approved"
}

get_in_progress_issues() {
  get_issues_by_board_status_with_comments "In Progress"
}

# Check stale using pre-fetched comments (no extra API calls)
# Args: number comments_json
check_stale() {
  local number="$1"
  local comments_json="$2"

  echo "[solver] Checking stale for issue #$number"

  # Find "[solver] Started at" comment from pre-fetched data
  local start_comment
  start_comment=$(echo "$comments_json" | jq -r '[.[] | select(startswith("[solver] Started at"))] | last // empty')

  if [[ -z "$start_comment" ]]; then
    echo "[solver] No '[solver] Started at' comment found for #$number — marking as failed"
    set_issue_status "$number" "Failed" "failed" "in-progress"
    gh issue comment "$number" --repo "$REPO" --body "[solver] Marked as failed: no start timestamp found."
    return
  fi

  # Extract timestamp from comment text: "[solver] Started at 2026-03-26T21:00:00Z"
  local start_time
  start_time=$(echo "$start_comment" | sed 's/\[solver\] Started at //')

  # Parse timestamp (macOS vs Linux)
  local started_epoch
  if started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" "+%s" 2>/dev/null); then
    : # macOS succeeded
  else
    started_epoch=$(date -d "$start_time" "+%s")
  fi

  local now_epoch
  now_epoch=$(date +%s)

  local elapsed=$(( now_epoch - started_epoch ))

  if [[ "$elapsed" -gt "$SOLVER_TIMEOUT" ]]; then
    echo "[solver] Issue #$number timed out (${elapsed}s > ${SOLVER_TIMEOUT}s)"

    # Cleanup worktree if exists
    if [[ -d "$WORKTREE_DIR/issue-$number" ]]; then
      git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR/issue-$number" --force || true
    fi

    set_issue_status "$number" "Failed" "failed" "in-progress"
    gh issue comment "$number" --repo "$REPO" --body "[solver] Marked as failed: timed out after ${elapsed}s (limit: ${SOLVER_TIMEOUT}s)."
  else
    echo "[solver] Issue #$number still within timeout (${elapsed}s / ${SOLVER_TIMEOUT}s)"
  fi
}

# Args: number title body comments_json
solve_issue() {
  local number="$1"
  local title="$2"
  local issue_body="$3"
  local comments_json="$4"

  if ! acquire_lock "$number"; then
    echo "[solver] Skipping #$number — already being processed"
    return
  fi
  trap 'release_lock "$number"' RETURN

  echo "[solver] Solving issue #$number — $title"

  # Swap status: approved -> in-progress
  set_issue_status "$number" "In Progress" "in-progress" "approved"

  # Comment with start timestamp
  local start_ts
  start_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  gh issue comment "$number" --repo "$REPO" --body "[solver] Started at $start_ts"

  # Format comments for prompt
  local issue_comments
  issue_comments=$(echo "$comments_json" | jq -r 'join("\n---\n")')

  # Determine branch type from checklist
  local branch_type="feature"
  if echo "$issue_body" | grep -qi "type" && echo "$issue_body" | grep -qi "bug"; then
    branch_type="bugfix"
  fi

  # Create slug from title
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40)

  local branch="${branch_type}/issue-${number}-${slug}"

  echo "[solver] Branch: $branch"

  # Update repo
  git -C "$REPO_DIR" fetch origin

  local base_branch="main"
  if git -C "$REPO_DIR" rev-parse --verify origin/develop &>/dev/null; then
    base_branch="develop"
  fi

  git -C "$REPO_DIR" checkout "$base_branch"
  git -C "$REPO_DIR" pull origin "$base_branch"

  # Reuse existing branch/worktree or create new
  local wt_dir="$WORKTREE_DIR/issue-$number"
  if [[ -d "$wt_dir" ]]; then
    echo "[solver] Reusing existing worktree at $wt_dir"
    git -C "$wt_dir" fetch origin 2>/dev/null
    git -C "$wt_dir" merge "$base_branch" --no-edit 2>/dev/null || true
  elif git -C "$REPO_DIR" rev-parse --verify "$branch" &>/dev/null; then
    echo "[solver] Reusing existing branch $branch"
    git -C "$REPO_DIR" worktree add "$wt_dir" "$branch"
    git -C "$wt_dir" merge "$base_branch" --no-edit 2>/dev/null || true
  else
    git -C "$REPO_DIR" worktree add "$wt_dir" -b "$branch"
  fi

  # Build prompt for claude
  local prompt
  prompt=$(cat <<PROMPT_EOF
You are solving GitHub issue #$number for this repository.

## Issue Title
$title

## Issue Body
$issue_body

## Issue Comments
$issue_comments

## Instructions
1. Read CLAUDE.md in the project root for project context and conventions.
2. Implement the solution for this issue.
3. Follow all coding conventions described in the project.
4. Make sure the code compiles/runs without errors or warnings.
5. Commit your changes with a message that includes "Closes #$number".
6. Do NOT push — the automation will handle pushing.
PROMPT_EOF
)

  # Run claude
  echo "[solver] Running claude on worktree $wt_dir"
  local claude_exit=0
  (cd "$wt_dir" && echo "$prompt" | claude --model "$CLAUDE_MODEL" -p) || claude_exit=$?

  if [[ "$claude_exit" -ne 0 ]]; then
    echo "[solver] Claude failed with exit code $claude_exit for #$number"
    set_issue_status "$number" "Failed" "failed" "in-progress"
    gh issue comment "$number" --repo "$REPO" --body "[solver] Failed: claude exited with code $claude_exit."
    git -C "$REPO_DIR" worktree remove "$wt_dir" --force || true
    return
  fi

  # Check if any commits were made
  local commit_count
  commit_count=$(git -C "$wt_dir" rev-list --count "$base_branch".."$branch" 2>/dev/null || echo "0")

  if [[ "$commit_count" -eq 0 ]]; then
    echo "[solver] No commits made for #$number — marking as failed"
    set_issue_status "$number" "Failed" "failed" "in-progress"
    gh issue comment "$number" --repo "$REPO" --body "[solver] Failed: claude produced no commits."
    git -C "$REPO_DIR" worktree remove "$wt_dir" --force || true
    return
  fi

  # Push branch
  echo "[solver] Pushing branch $branch"
  git -C "$wt_dir" push -u origin "$branch"

  # Create PR
  local pr_url
  pr_url=$(gh pr create --repo "$REPO" --head "$branch" --base "$base_branch" --title "$title" --body "$(cat <<PR_EOF
Closes #$number

Automated by gh-claudecode solver.
PR_EOF
)")

  echo "[solver] PR created: $pr_url"

  # Move to In Review — worktree stays alive for potential retry
  set_issue_status "$number" "In Review" "in-review" "in-progress"

  # Comment with PR URL
  gh issue comment "$number" --repo "$REPO" --body "[solver] PR created: $pr_url — awaiting review."

  echo "[solver] Issue #$number → In Review (worktree kept at $wt_dir)"
}

# Check PRs in "In Review" status
# - Merged → Done + cleanup worktree
# - Changes requested → retry with review feedback
# - Closed without merge → Failed + cleanup worktree
check_reviews() {
  local review_issues
  review_issues=$(get_issues_by_board_status_with_comments "In Review")
  local review_count
  review_count=$(echo "$review_issues" | jq 'length')

  if [[ "$review_count" -eq 0 ]]; then
    return
  fi

  echo "[solver] Found $review_count issue(s) in review"

  echo "$review_issues" | jq -c '.[]' | while IFS= read -r item; do
    local number title
    number=$(echo "$item" | jq -r '.number')
    title=$(echo "$item" | jq -r '.title')

    # Find the PR for this issue
    local pr_json
    pr_json=$(gh pr list --repo "$REPO" --json number,state,reviewDecision,headRefName \
      --search "Closes #$number" --limit 1 2>/dev/null)

    local pr_count
    pr_count=$(echo "$pr_json" | jq 'length')

    if [[ "$pr_count" -eq 0 ]]; then
      echo "[solver] No PR found for issue #$number — skipping"
      continue
    fi

    local pr_number pr_state review_decision branch
    pr_number=$(echo "$pr_json" | jq -r '.[0].number')
    pr_state=$(echo "$pr_json" | jq -r '.[0].state')
    review_decision=$(echo "$pr_json" | jq -r '.[0].reviewDecision // ""')
    branch=$(echo "$pr_json" | jq -r '.[0].headRefName')

    local wt_dir="$WORKTREE_DIR/issue-$number"

    if [[ "$pr_state" == "MERGED" ]]; then
      echo "[solver] PR #$pr_number merged for issue #$number"
      set_issue_status "$number" "Done" "done" "in-review"
      gh issue comment "$number" --repo "$REPO" --body "[solver] PR #$pr_number merged. Done!"
      # Cleanup worktree
      if [[ -d "$wt_dir" ]]; then
        git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
      fi

    elif [[ "$pr_state" == "CLOSED" ]]; then
      echo "[solver] PR #$pr_number closed without merge for issue #$number"
      set_issue_status "$number" "Failed" "failed" "in-review"
      gh issue comment "$number" --repo "$REPO" --body "[solver] PR #$pr_number was closed without merge. Marked as failed."
      if [[ -d "$wt_dir" ]]; then
        git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
      fi

    elif [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
      echo "[solver] Changes requested on PR #$pr_number for issue #$number — retrying"

      # Get review comments
      local review_comments
      review_comments=$(gh pr view "$pr_number" --repo "$REPO" --json reviews \
        --jq '[.reviews[] | select(.state == "CHANGES_REQUESTED") | .body] | join("\n---\n")' 2>/dev/null)

      # Get inline review comments
      local inline_comments
      inline_comments=$(gh api "repos/$REPO/pulls/$pr_number/comments" \
        --jq '[.[] | "\(.path):\(.line // .original_line): \(.body)"] | join("\n")' 2>/dev/null)

      if [[ ! -d "$wt_dir" ]]; then
        echo "[solver] Worktree missing for issue #$number — recreating"
        git -C "$REPO_DIR" fetch origin
        git -C "$REPO_DIR" worktree add "$wt_dir" "$branch" 2>/dev/null || {
          echo "[solver] Could not recreate worktree for #$number"
          return
        }
      fi

      # Pull latest
      git -C "$wt_dir" pull origin "$branch" 2>/dev/null || true

      local retry_prompt
      retry_prompt=$(cat <<RETRY_EOF
You are fixing a GitHub PR that received "changes requested" review feedback.

## Issue #$number: $title

## Review Feedback
$review_comments

## Inline Comments
$inline_comments

## Instructions
1. Read CLAUDE.md in the project root for project context and conventions.
2. Address ALL review feedback above.
3. Make sure the code compiles/runs without errors or warnings.
4. Commit your fixes with a descriptive message.
5. Do NOT push — the automation will handle pushing.
RETRY_EOF
)

      local claude_exit=0
      (cd "$wt_dir" && echo "$retry_prompt" | claude --model "$CLAUDE_MODEL" -p) || claude_exit=$?

      if [[ "$claude_exit" -ne 0 ]]; then
        echo "[solver] Claude retry failed for #$number (exit $claude_exit)"
        gh issue comment "$number" --repo "$REPO" --body "[solver] Retry failed: claude exited with code $claude_exit."
        return
      fi

      # Push new commits (updates the existing PR)
      git -C "$wt_dir" push origin "$branch" 2>/dev/null

      gh pr comment "$pr_number" --repo "$REPO" --body "[solver] Review feedback addressed. Please re-review."
      echo "[solver] Pushed fixes for PR #$pr_number"

    else
      echo "[solver] PR #$pr_number for issue #$number — waiting for review"
    fi
  done
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

echo "[solver] Starting for $REPO (interval: ${SOLVER_INTERVAL}s, timeout: ${SOLVER_TIMEOUT}s, model: $CLAUDE_MODEL)"

init_project_board || true

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

while true; do
  echo ""
  echo "[solver] Polling at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # --- In-progress issues (stale check placeholder) ---
  in_progress=$(get_in_progress_issues)
  in_progress_count=$(echo "$in_progress" | jq 'length')
  echo "[solver] Found $in_progress_count in-progress issue(s)"

  if [[ "$in_progress_count" -gt 0 ]]; then
    echo "$in_progress" | jq -c '.[]' | while read -r issue; do
      ip_number=$(echo "$issue" | jq -r '.number')
      ip_comments=$(echo "$issue" | jq -c '.comments')
      check_stale "$ip_number" "$ip_comments"
    done
  fi

  # --- Approved issues (pick first one, sequential) ---
  approved=$(get_approved_issues)
  approved_count=$(echo "$approved" | jq 'length')
  echo "[solver] Found $approved_count approved issue(s)"

  if [[ "$approved_count" -gt 0 ]]; then
    first=$(echo "$approved" | jq -c '.[0]')
    number=$(echo "$first" | jq -r '.number')
    title=$(echo "$first" | jq -r '.title')
    body=$(echo "$first" | jq -r '.body')
    comments_json=$(echo "$first" | jq -c '.comments')
    echo "[solver] Next issue to solve: #$number — $title"

    solve_issue "$number" "$title" "$body" "$comments_json"
  fi

  # --- In Review issues (PR monitoring) ---
  check_reviews

  echo "[solver] Sleeping ${SOLVER_INTERVAL}s..."
  sleep "$SOLVER_INTERVAL"
done
