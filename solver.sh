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
PROJECT_NUMBER="${PROJECT_NUMBER:-1}"
SOLVER_INTERVAL="${SOLVER_INTERVAL:-600}"
SOLVER_TIMEOUT="${SOLVER_TIMEOUT:-3600}"
SOLVER_PARALLEL="${SOLVER_PARALLEL:-3}"
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
    --parallel)
      SOLVER_PARALLEL="$2"
      shift 2
      ;;
    --model)
      CLAUDE_MODEL="$2"
      shift 2
      ;;
    --project)
      PROJECT_NUMBER="$2"
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

# Worktrees inside the repo
WORKTREE_DIR="$REPO_DIR/.worktrees"
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

# Clean stale locks on startup (from previous crashed runs)
find "$LOCK_DIR" -name "solver-issue-*" -type d -exec rmdir {} + 2>/dev/null || true

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
  get_issues_by_board_status_with_comments "TODO"
}

get_in_progress_issues() {
  get_issues_by_board_status "In Progress"
}

# Check stale based on log file modification time (not comments)
# If the log file hasn't been modified in SOLVER_TIMEOUT seconds, the process is stuck
# Args: number
check_stale() {
  local number="$1"
  local issue_log="$LOG_DIR/issue-${number}.log"

  # No log file = process hasn't started writing yet, skip
  if [[ ! -f "$issue_log" ]]; then
    echo "[solver] No log file for issue #$number — skipping stale check"
    return
  fi

  # Get last modification time of log file
  local last_mod now_epoch idle
  if last_mod=$(stat -f %m "$issue_log" 2>/dev/null); then
    : # macOS
  else
    last_mod=$(stat -c %Y "$issue_log" 2>/dev/null) # Linux
  fi
  now_epoch=$(date +%s)
  idle=$(( now_epoch - last_mod ))

  if [[ "$idle" -gt "$SOLVER_TIMEOUT" ]]; then
    echo "[solver] Issue #$number log idle for ${idle}s (limit: ${SOLVER_TIMEOUT}s) — marking as failed"

    # Sync worktree to develop before marking as failed
    local stale_wt="$WORKTREE_DIR/issue-$number"
    if [[ -d "$stale_wt" ]]; then
      local stale_branch
      stale_branch=$(git -C "$stale_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      if [[ -n "$stale_branch" ]]; then
        sync_worktree_to_develop "$REPO_DIR" "$stale_wt" "$stale_branch" "$number"
      fi
    fi

    set_issue_status "$number" "Failed" "failed"
    post_execution_log "$LOG_DIR" "$number" "solver" "Failed" "log idle for ${idle}s (limit: ${SOLVER_TIMEOUT}s)"
  else
    echo "[solver] Issue #$number log active (${idle}s idle)"
  fi
}

# Args: number title body comments_json
# All output is redirected to LOG_DIR/issue-{N}.log
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

  # Archive previous execution log before starting new run
  local issue_log="$LOG_DIR/issue-${number}.log"
  post_execution_log "$LOG_DIR" "$number" "solver" "previous run"
  : > "$issue_log"  # clear for new run

  echo "[solver] Solving issue #$number — $title" | tee -a "$issue_log"

  # Swap status: approved -> in-progress
  set_issue_status "$number" "In Progress" "in-progress"

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

  local base_branch="main"
  if git -C "$REPO_DIR" rev-parse --verify origin/develop &>/dev/null; then
    base_branch="develop"
  fi

  # Setup worktree — clean any broken state first
  local wt_dir="$WORKTREE_DIR/issue-$number"
  echo "[solver] Setting up worktree at $wt_dir for branch $branch" >> "$issue_log"

  # Step 1: Clean any orphaned worktree reference
  git -C "$REPO_DIR" worktree prune 2>&1 >> "$issue_log"

  # Step 2: Remove existing worktree dir if it exists but is broken
  if [[ -d "$wt_dir" ]]; then
    if ! git -C "$wt_dir" status &>/dev/null; then
      echo "[solver] Removing broken worktree at $wt_dir" >> "$issue_log"
      git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>&1 >> "$issue_log" || rm -rf "$wt_dir"
    fi
  fi

  # Step 3: If worktree dir still exists and is valid, reuse it
  if [[ -d "$wt_dir" ]] && git -C "$wt_dir" status &>/dev/null; then
    echo "[solver] Reusing existing worktree" >> "$issue_log"
    git -C "$wt_dir" fetch origin 2>&1 >> "$issue_log" || true
    git -C "$wt_dir" checkout "$branch" 2>&1 >> "$issue_log" || true
    git -C "$wt_dir" reset --hard "origin/$branch" 2>&1 >> "$issue_log" || true
    git -C "$wt_dir" merge "origin/$base_branch" --no-edit 2>&1 >> "$issue_log" || true
  else
    # Step 4: Create fresh worktree — clean local branch first
    git -C "$REPO_DIR" branch -D "$branch" 2>/dev/null || true

    if git -C "$REPO_DIR" rev-parse --verify "origin/$branch" &>/dev/null; then
      echo "[solver] Creating worktree from remote branch origin/$branch" >> "$issue_log"
      git -C "$REPO_DIR" worktree add "$wt_dir" -b "$branch" "origin/$branch" 2>&1 >> "$issue_log" || {
        # Fallback: detached HEAD from remote branch
        git -C "$REPO_DIR" worktree add "$wt_dir" "origin/$branch" 2>&1 >> "$issue_log" || {
          echo "[solver] ERROR: all worktree creation attempts failed" >> "$issue_log"
        }
      }
    else
      echo "[solver] Creating new worktree from origin/$base_branch" >> "$issue_log"
      git -C "$REPO_DIR" worktree add "$wt_dir" -b "$branch" "origin/$base_branch" 2>&1 >> "$issue_log" || {
        echo "[solver] ERROR: worktree creation failed" >> "$issue_log"
      }
    fi

    # Merge develop into the new branch
    if [[ -d "$wt_dir" ]]; then
      git -C "$wt_dir" merge "origin/$base_branch" --no-edit 2>&1 >> "$issue_log" || true
    fi
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
5. Commit your changes with a message that references "issue #$number" (do NOT use "Closes" or "Fixes" — the issue will be closed manually).
6. Do NOT push — the automation will handle pushing.
PROMPT_EOF
)

  # Verify worktree exists
  if [[ ! -d "$wt_dir" ]]; then
    echo "[solver] ERROR: worktree $wt_dir does not exist!" | tee -a "$issue_log"
    set_issue_status "$number" "Failed" "failed"
    post_execution_log "$LOG_DIR" "$number" "solver" "Failed" "worktree does not exist: $wt_dir"
    return
  fi

  # Run claude with stream-json — output direct to file (unbuffered, one JSON line per event)
  echo "[solver] Running claude on worktree $wt_dir" >> "$issue_log"
  local claude_exit=0

  # Claude writes directly to log file — no pipe buffering
  (cd "$wt_dir" && echo "$prompt" | claude --model "$CLAUDE_MODEL" --output-format stream-json --verbose -p >> "$issue_log" 2>&1) || claude_exit=$?

  # Extract final result for display
  local final_result
  final_result=$(grep '"type":"result"' "$issue_log" | tail -1 | jq -r '.result // empty' 2>/dev/null)
  if [[ -n "$final_result" ]]; then
    echo "[solver] Claude done: $(echo "$final_result" | head -3)"
  fi

  if [[ "$claude_exit" -ne 0 ]]; then
    echo "[solver] Claude failed with exit code $claude_exit for #$number" | tee -a "$issue_log"
    sync_worktree_to_develop "$REPO_DIR" "$wt_dir" "$branch" "$number"
    set_issue_status "$number" "Failed" "failed"
    post_execution_log "$LOG_DIR" "$number" "solver" "Failed" "claude exited with code $claude_exit"
    return
  fi

  # Check if any commits were made
  local commit_count
  commit_count=$(git -C "$wt_dir" rev-list --count "origin/$base_branch".."$branch" 2>/dev/null || echo "0")

  if [[ "$commit_count" -eq 0 ]]; then
    echo "[solver] No commits made for #$number — marking as failed" | tee -a "$issue_log"
    sync_worktree_to_develop "$REPO_DIR" "$wt_dir" "$branch" "$number"
    set_issue_status "$number" "Failed" "failed"
    post_execution_log "$LOG_DIR" "$number" "solver" "Failed" "claude produced no commits"
    return
  fi

  # Sync: commit, push, merge to develop
  sync_worktree_to_develop "$REPO_DIR" "$wt_dir" "$branch" "$number"

  # Create PR if doesn't exist
  local existing_pr
  existing_pr=$(gh pr list --repo "$REPO" --head "$branch" --json number -q '.[0].number' 2>/dev/null)

  local pr_url
  if [[ -n "$existing_pr" ]]; then
    pr_url="https://github.com/$REPO/pull/$existing_pr"
    echo "[solver] PR already exists: $pr_url"
  else
    pr_url=$(gh pr create --repo "$REPO" --head "$branch" --base "$base_branch" --title "$title" --body "$(cat <<PR_EOF
Related to #$number

Automated by gh-claudecode solver.
PR_EOF
)")
    echo "[solver] PR created: $pr_url" | tee -a "$issue_log"
  fi

  # Move to In Review
  set_issue_status "$number" "In Review" "in-review"

  # Post execution log (success) and comment with PR
  post_execution_log "$LOG_DIR" "$number" "solver" "Success" "PR created: $pr_url"

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

    # Find the PR for this issue by branch name pattern
    local pr_json
    pr_json=$(gh pr list --repo "$REPO" --state all --json number,state,reviewDecision,headRefName \
      --jq "[.[] | select(.headRefName | contains(\"issue-$number\"))]" 2>/dev/null)

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
      set_issue_status "$number" "Done" "done"
      gh issue comment "$number" --repo "$REPO" --body "[solver] PR #$pr_number merged. Done!"
      # Pull develop to get merged changes
      git -C "$REPO_DIR" checkout develop 2>/dev/null
      git -C "$REPO_DIR" pull origin develop 2>/dev/null
      echo "[solver] ✓ Develop worktree updated"
      # Cleanup worktree
      if [[ -d "$wt_dir" ]]; then
        git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
      fi

    elif [[ "$pr_state" == "CLOSED" ]]; then
      echo "[solver] PR #$pr_number closed without merge for issue #$number"
      set_issue_status "$number" "Failed" "failed"
      gh issue comment "$number" --repo "$REPO" --body "[solver] PR #$pr_number was closed without merge. Marked as failed."
      if [[ -d "$wt_dir" ]]; then
        git -C "$REPO_DIR" worktree remove "$wt_dir" --force 2>/dev/null || true
      fi

    else
      # Check for human feedback: PR comments, review bodies, inline code comments
      local SOLVER_MARKER="<!-- gh-claudecode:solver -->"

      # Get last PR comment
      local last_pr_comment
      last_pr_comment=$(gh pr view "$pr_number" --repo "$REPO" --json comments \
        --jq '.comments[-1].body // ""' 2>/dev/null)

      # Get review bodies (formal reviews)
      local review_bodies
      review_bodies=$(gh pr view "$pr_number" --repo "$REPO" --json reviews \
        --jq '[.reviews[] | select(.body != "") | .body] | join("\n---\n")' 2>/dev/null)

      # Get inline code review comments
      local inline_comments
      inline_comments=$(gh api "repos/$REPO/pulls/$pr_number/comments" \
        --jq '[.[] | "\(.path):\(.line // .original_line): \(.body)"] | join("\n")' 2>/dev/null)

      # Determine if there's new human feedback
      local has_feedback=false
      if [[ -n "$last_pr_comment" ]] && ! echo "$last_pr_comment" | grep -qF "$SOLVER_MARKER"; then
        has_feedback=true
      fi
      if [[ -n "$review_bodies" ]]; then
        has_feedback=true
      fi
      if [[ -n "$inline_comments" ]]; then
        has_feedback=true
      fi

      if [[ "$has_feedback" == "true" ]]; then
        echo "[solver] Human feedback on PR #$pr_number for issue #$number — retrying"

        set_issue_status "$number" "In Progress" "in-progress"

        # Clear previous logs for this issue
        rm -f "$LOG_DIR/issue-${number}.log"

        # Collect all human PR comments
        local pr_comments_text
        pr_comments_text=$(gh pr view "$pr_number" --repo "$REPO" --json comments \
          --jq "[.comments[] | select(.body | contains(\"$SOLVER_MARKER\") | not) | .body] | join(\"\n---\n\")" 2>/dev/null)

        if [[ ! -d "$wt_dir" ]]; then
          echo "[solver] Worktree missing for issue #$number — recreating"
          git -C "$REPO_DIR" fetch origin
          git -C "$REPO_DIR" worktree add "$wt_dir" "$branch" 2>/dev/null || {
            echo "[solver] Could not recreate worktree for #$number"
            continue
          }
        fi

        git -C "$wt_dir" pull origin "$branch" 2>/dev/null || true

        local retry_prompt
        retry_prompt=$(cat <<RETRY_EOF
You are fixing a GitHub PR that received feedback from the reviewer.

## Issue #$number: $title

## PR Comments
$pr_comments_text

## Review Comments
$review_bodies

## Inline Code Comments
$inline_comments

## Instructions
1. Read CLAUDE.md in the project root for project context and conventions.
2. Address ALL reviewer feedback above (PR comments, review comments, and inline code comments).
3. Make sure the code compiles/runs without errors or warnings.
4. Commit your fixes with a descriptive message.
5. Do NOT push — the automation will handle pushing.
RETRY_EOF
)

        local claude_log="$LOG_DIR/issue-${number}.log"
        : > "$claude_log"
        local claude_exit=0

        cd "$wt_dir" && echo "$retry_prompt" | claude --model "$CLAUDE_MODEL" --output-format stream-json --verbose -p >> "$claude_log" 2>&1 || claude_exit=$?
        cd "$SCRIPT_DIR"

        local gist_url=""
        if [[ -f "$claude_log" ]]; then
          gist_url=$(upload_log_gist "$number" "$claude_log" "retry output")
        fi
        local log_link=""
        if [[ -n "$gist_url" ]]; then
          log_link="
[Full claude output log]($gist_url)"
        fi

        if [[ "$claude_exit" -ne 0 ]]; then
          echo "[solver] Claude retry failed for #$number (exit $claude_exit)"
          gh pr comment "$pr_number" --repo "$REPO" --body "${SOLVER_MARKER}
Retry failed: claude exited with code $claude_exit.$log_link"
          set_issue_status "$number" "In Review" "in-review"
          continue
        fi

        git -C "$wt_dir" push origin "$branch" 2>/dev/null || {
          git -C "$wt_dir" push origin "$branch" --force-with-lease 2>/dev/null || {
            echo "[solver] Could not push retry fixes for #$number"
            set_issue_status "$number" "In Review" "in-review"
            continue
          }
        }

        # Merge into develop worktree
        merge_to_develop "$REPO_DIR" "$branch" || true

        gh pr comment "$pr_number" --repo "$REPO" --body "${SOLVER_MARKER}
Feedback addressed. Please re-review.$log_link"

        set_issue_status "$number" "In Review" "in-review"
        echo "[solver] Pushed fixes for PR #$pr_number"

      else
        echo "[solver] PR #$pr_number for issue #$number — waiting for review"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

echo "[solver] Starting for $REPO (interval: ${SOLVER_INTERVAL}s, timeout: ${SOLVER_TIMEOUT}s, parallel: ${SOLVER_PARALLEL}, model: $CLAUDE_MODEL)"

ensure_project_ready "$REPO"
init_project_board || true

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

# Log directory inside target repo
LOG_DIR="$REPO_DIR/.logs"
mkdir -p "$LOG_DIR"

while true; do
  echo ""
  # Clean all locks at start of each cycle
  find "$LOCK_DIR" -name "solver-issue-*" -type d -exec rmdir {} + 2>/dev/null || true

  local_cycle_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  echo "[solver] Polling at $local_cycle_ts"

  # --- Approved issues first (parallel) ---
  approved=$(get_approved_issues)
  approved_count=$(echo "$approved" | jq 'length')
  echo "[solver] Found $approved_count approved issue(s)"

  # Update repo ONCE before parallel processing
  if [[ "$approved_count" -gt 0 ]]; then
    git -C "$REPO_DIR" fetch origin 2>/dev/null
    if git -C "$REPO_DIR" rev-parse --verify origin/develop &>/dev/null; then
      git -C "$REPO_DIR" checkout develop 2>/dev/null
      git -C "$REPO_DIR" pull origin develop 2>/dev/null
    else
      git -C "$REPO_DIR" checkout main 2>/dev/null
      git -C "$REPO_DIR" pull origin main 2>/dev/null
    fi
  fi

  running=0
  processed_issues=""
  echo "$approved" | jq -c '.[]' | while IFS= read -r item; do
    number=$(echo "$item" | jq -r '.number')
    title=$(echo "$item" | jq -r '.title')
    body=$(echo "$item" | jq -r '.body')
    comments_json=$(echo "$item" | jq -c '.comments')

    echo "[solver] Starting issue #$number — $title (log: $LOG_DIR/issue-${number}.log)"

    solve_issue "$number" "$title" "$body" "$comments_json" &
    running=$((running + 1))
    if [[ "$running" -ge "$SOLVER_PARALLEL" ]]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done
  wait

  # --- Cycle summary ---
  if [[ "$approved_count" -gt 0 ]]; then
    echo ""
    echo "[solver] === Cycle Summary ==="
    for logfile in "$LOG_DIR"/issue-*.log; do
      [[ -f "$logfile" ]] || continue
      local_issue_num=$(basename "$logfile" .log | sed 's/issue-//')
      local_result="unknown"
      if grep -q "In Review" "$logfile" 2>/dev/null; then
        local_result="✓ PR created"
      elif grep -q "Failed" "$logfile" 2>/dev/null; then
        local_result="✗ Failed"
      elif grep -q "already being processed" "$logfile" 2>/dev/null; then
        local_result="⊘ Skipped (locked)"
      fi
      local_pr=$(grep -o "PR created: [^ ]*" "$logfile" 2>/dev/null | head -1 | sed 's/PR created: //')
      echo "[solver]   #$local_issue_num → $local_result ${local_pr:-}"
    done
    echo "[solver] ========================"
    echo ""

    # Upload combined cycle log as gist
    cycle_log="$LOG_DIR/cycle-$(date -u '+%Y%m%dT%H%M%SZ').log"
    cat "$LOG_DIR"/issue-*.log > "$cycle_log" 2>/dev/null
    if [[ -s "$cycle_log" ]]; then
      cycle_gist=$(upload_log_gist "cycle" "$cycle_log" "solver cycle $local_cycle_ts")
      if [[ -n "$cycle_gist" ]]; then
        echo "[solver] Full cycle log: $cycle_gist"
      fi
    fi

  fi

  # --- In-progress issues (stale check — after processing approved) ---
  in_progress=$(get_in_progress_issues)
  in_progress_count=$(echo "$in_progress" | jq 'length')
  if [[ "$in_progress_count" -gt 0 ]]; then
    echo "[solver] Checking $in_progress_count in-progress issue(s) for staleness"
    echo "$in_progress" | jq -c '.[]' | while read -r issue; do
      ip_number=$(echo "$issue" | jq -r '.number')
      check_stale "$ip_number"
    done
  fi

  # --- In Review issues (PR monitoring) ---
  check_reviews

  echo "[solver] Sleeping ${SOLVER_INTERVAL}s..."
  sleep "$SOLVER_INTERVAL"
done
