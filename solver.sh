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

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --interval) SOLVER_INTERVAL="$2"; shift 2 ;;
    --timeout) SOLVER_TIMEOUT="$2"; shift 2 ;;
    --parallel) SOLVER_PARALLEL="$2"; shift 2 ;;
    --model) CLAUDE_MODEL="$2"; shift 2 ;;
    --project) PROJECT_NUMBER="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    *) echo "[solver] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "[solver] Error: --repo is required" >&2
  exit 1
fi

REPO=$(normalize_repo "$REPO")

for cmd in gh claude jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[solver] Error: '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Repo setup
# ---------------------------------------------------------------------------

if [[ -z "$REPO_DIR" ]]; then
  echo "[solver] Error: --repo-dir is required" >&2
  exit 1
fi

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "[solver] Error: $REPO_DIR is not a git repository" >&2
  exit 1
fi

# Solver clones dir: inside the target repo
SOLVERS_DIR="$REPO_DIR/.solvers"
mkdir -p "$SOLVERS_DIR"

# Log dir: inside the target repo
LOG_DIR="$REPO_DIR/.logs"
mkdir -p "$LOG_DIR"

# Lock dir
LOCK_DIR="$SCRIPT_DIR/.locks"
mkdir -p "$LOCK_DIR"

echo "[solver] Using repo at $REPO_DIR"
echo "[solver] Solver clones at $SOLVERS_DIR"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

acquire_lock() {
  mkdir "$LOCK_DIR/solver-issue-$1" 2>/dev/null && return 0
  return 1
}

release_lock() {
  rmdir "$LOCK_DIR/solver-issue-$1" 2>/dev/null || true
}

get_approved_issues() {
  get_issues_by_board_status_with_comments "TODO"
}

get_in_progress_issues() {
  get_issues_by_board_status "In Progress"
}

# Check stale based on log file idle time
check_stale() {
  local number="$1"
  local issue_log="$LOG_DIR/issue-${number}.log"

  if [[ ! -f "$issue_log" ]]; then
    return
  fi

  local last_mod now_epoch idle
  if last_mod=$(stat -f %m "$issue_log" 2>/dev/null); then :
  else last_mod=$(stat -c %Y "$issue_log" 2>/dev/null); fi
  now_epoch=$(date +%s)
  idle=$(( now_epoch - last_mod ))

  if [[ "$idle" -gt "$SOLVER_TIMEOUT" ]]; then
    echo "[solver] Issue #$number log idle for ${idle}s (limit: ${SOLVER_TIMEOUT}s) — marking as failed"

    # Commit and push any partial work
    local clone_dir="$SOLVERS_DIR/issue-$number"
    if [[ -d "$clone_dir" ]]; then
      local branch
      branch=$(git -C "$clone_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
        git -C "$clone_dir" add -A 2>/dev/null
        git -C "$clone_dir" commit -m "WIP: partial work on issue #$number" 2>/dev/null || true
        git -C "$clone_dir" push origin "$branch" 2>/dev/null || true
      fi
    fi

    local stale_gist
    stale_gist=$(upload_execution_log "$LOG_DIR" "$number" "solver" "timeout")
    local stale_link=""
    [[ -n "$stale_gist" ]] && stale_link="

---
[execution log]($stale_gist)"

    set_issue_status "$number" "Failed" "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: log idle for ${idle}s (limit: ${SOLVER_TIMEOUT}s)${stale_link}" 2>/dev/null || true
  else
    echo "[solver] Issue #$number log active (${idle}s idle)"
  fi
}

# Main solve function
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

  # Setup log
  local issue_log="$LOG_DIR/issue-${number}.log"
  upload_execution_log "$LOG_DIR" "$number" "solver" "previous run"
  : > "$issue_log"

  echo "[solver] Solving issue #$number — $title" | tee -a "$issue_log"

  set_issue_status "$number" "In Progress" "in-progress"

  # Determine branch
  local branch_type="feature"
  if echo "$issue_body" | grep -qi "type" && echo "$issue_body" | grep -qi "bug"; then
    branch_type="bugfix"
  fi
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40)
  local branch="${branch_type}/issue-${number}-${slug}"

  local base_branch="main"
  if git -C "$REPO_DIR" rev-parse --verify origin/develop &>/dev/null; then
    base_branch="develop"
  fi

  echo "[solver] Branch: $branch (base: $base_branch)" >> "$issue_log"

  # Setup clone for this issue
  local clone_dir="$SOLVERS_DIR/issue-$number"

  if [[ -d "$clone_dir" ]]; then
    echo "[solver] Reusing existing clone at $clone_dir" >> "$issue_log"
    git -C "$clone_dir" fetch origin 2>&1 >> "$issue_log" || true
  else
    echo "[solver] Cloning repo for issue #$number" >> "$issue_log"
    git clone --reference "$REPO_DIR" "$(git -C "$REPO_DIR" remote get-url origin)" "$clone_dir" 2>&1 >> "$issue_log" || {
      echo "[solver] ERROR: clone failed" >> "$issue_log"
      local clone_gist
      clone_gist=$(upload_execution_log "$LOG_DIR" "$number" "solver" "clone-failed")
      local clone_link=""
      [[ -n "$clone_gist" ]] && clone_link="

---
[execution log]($clone_gist)"
      set_issue_status "$number" "Failed" "failed"
      gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: git clone failed${clone_link}" 2>/dev/null || true
      return
    }
  fi

  # Checkout or create branch
  if git -C "$clone_dir" rev-parse --verify "origin/$branch" &>/dev/null; then
    echo "[solver] Checking out existing branch $branch" >> "$issue_log"
    git -C "$clone_dir" checkout "$branch" 2>&1 >> "$issue_log" || {
      git -C "$clone_dir" checkout -b "$branch" "origin/$branch" 2>&1 >> "$issue_log" || true
    }
    git -C "$clone_dir" pull origin "$branch" 2>&1 >> "$issue_log" || true
    git -C "$clone_dir" merge "origin/$base_branch" --no-edit 2>&1 >> "$issue_log" || true
  else
    echo "[solver] Creating new branch $branch from $base_branch" >> "$issue_log"
    git -C "$clone_dir" checkout "origin/$base_branch" 2>&1 >> "$issue_log" || true
    git -C "$clone_dir" checkout -b "$branch" 2>&1 >> "$issue_log" || true
  fi

  # Format comments
  local issue_comments
  issue_comments=$(echo "$comments_json" | jq -r 'join("\n---\n")')

  # Build prompt
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

  # Verify clone exists
  if [[ ! -d "$clone_dir/.git" ]]; then
    echo "[solver] ERROR: clone dir $clone_dir does not exist!" | tee -a "$issue_log"
    local missing_gist
    missing_gist=$(upload_execution_log "$LOG_DIR" "$number" "solver" "missing-clone")
    local missing_link=""
    [[ -n "$missing_gist" ]] && missing_link="

---
[execution log]($missing_gist)"
    set_issue_status "$number" "Failed" "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: clone directory missing${missing_link}" 2>/dev/null || true
    return
  fi

  # Run claude with stream-json
  echo "[solver] Running claude on $clone_dir" >> "$issue_log"
  local claude_exit=0
  (cd "$clone_dir" && echo "$prompt" | claude --model "$CLAUDE_MODEL" --output-format stream-json --verbose -p >> "$issue_log" 2>&1) || claude_exit=$?

  # Upload gist now so all exit paths can include the link
  local gist_url
  gist_url=$(upload_execution_log "$LOG_DIR" "$number" "solver" "solve-issue")
  local log_link=""
  [[ -n "$gist_url" ]] && log_link="

---
[execution log]($gist_url)"

  # Extract result
  local final_result
  final_result=$(grep '"type":"result"' "$issue_log" | tail -1 | jq -r '.result // empty' 2>/dev/null)
  if [[ -n "$final_result" ]]; then
    echo "[solver] Claude done: $(echo "$final_result" | head -3)"
  fi

  if [[ "$claude_exit" -ne 0 ]]; then
    echo "[solver] Claude failed with exit code $claude_exit for #$number"
    git -C "$clone_dir" add -A 2>/dev/null
    git -C "$clone_dir" commit -m "WIP: partial work on issue #$number" 2>/dev/null || true
    git -C "$clone_dir" push origin "$branch" 2>/dev/null || true
    set_issue_status "$number" "Failed" "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: claude exited with code $claude_exit${log_link}" 2>/dev/null || true
    return
  fi

  # Check commits
  local commit_count
  commit_count=$(git -C "$clone_dir" rev-list --count "origin/$base_branch"..HEAD 2>/dev/null || echo "0")

  if [[ "$commit_count" -eq 0 ]]; then
    echo "[solver] No commits made for #$number"
    set_issue_status "$number" "Failed" "failed"
    gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: claude produced no commits${log_link}" 2>/dev/null || true
    return
  fi

  # Push
  git -C "$clone_dir" push -u origin "$branch" 2>/dev/null || {
    git -C "$clone_dir" push -u origin "$branch" --force-with-lease 2>/dev/null || {
      echo "[solver] Push failed for #$number"
      set_issue_status "$number" "Failed" "failed"
      gh issue comment "$number" --repo "$REPO" --body "[solver] **Failed**: push failed${log_link}" 2>/dev/null || true
      return
    }
  }

  # Create PR if doesn't exist
  local existing_pr
  existing_pr=$(gh pr list --repo "$REPO" --head "$branch" --json number -q '.[0].number' 2>/dev/null)

  local pr_url
  if [[ -n "$existing_pr" ]]; then
    pr_url="https://github.com/$REPO/pull/$existing_pr"
  else
    pr_url=$(gh pr create --repo "$REPO" --head "$branch" --base "$base_branch" --title "$title" --body "$(cat <<PR_EOF
Related to #$number

Automated by gh-claudecode solver.
PR_EOF
)")
  fi

  set_issue_status "$number" "In Review" "in-review"
  gh issue comment "$number" --repo "$REPO" --body "[solver] **Success**: PR created: $pr_url${log_link}" 2>/dev/null || true

  echo "[solver] Issue #$number → In Review"
}

# Check PRs in "In Review"
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

    local pr_json
    pr_json=$(gh pr list --repo "$REPO" --state all --json number,state,reviewDecision,headRefName \
      --jq "[.[] | select(.headRefName | contains(\"issue-$number\"))]" 2>/dev/null)

    local pr_count
    pr_count=$(echo "$pr_json" | jq 'length')

    if [[ "$pr_count" -eq 0 ]]; then
      echo "[solver] No PR found for issue #$number — skipping"
      continue
    fi

    local pr_number pr_state branch
    pr_number=$(echo "$pr_json" | jq -r '.[0].number')
    pr_state=$(echo "$pr_json" | jq -r '.[0].state')
    branch=$(echo "$pr_json" | jq -r '.[0].headRefName')

    local clone_dir="$SOLVERS_DIR/issue-$number"

    if [[ "$pr_state" == "MERGED" ]]; then
      echo "[solver] PR #$pr_number merged for issue #$number"
      set_issue_status "$number" "Done" "done"
      gh issue comment "$number" --repo "$REPO" --body "[solver] PR #$pr_number merged. Done!"
      # Cleanup clone
      rm -rf "$clone_dir"

    elif [[ "$pr_state" == "CLOSED" ]]; then
      echo "[solver] PR #$pr_number closed without merge for issue #$number"
      set_issue_status "$number" "Failed" "failed"
      gh issue comment "$number" --repo "$REPO" --body "[solver] PR #$pr_number was closed without merge."
      rm -rf "$clone_dir"

    else
      # Check for human feedback
      local SOLVER_MARKER="<!-- gh-claudecode:solver -->"

      local last_pr_comment
      last_pr_comment=$(gh pr view "$pr_number" --repo "$REPO" --json comments \
        --jq '.comments[-1].body // ""' 2>/dev/null)

      local review_bodies
      review_bodies=$(gh pr view "$pr_number" --repo "$REPO" --json reviews \
        --jq '[.reviews[] | select(.body != "") | .body] | join("\n---\n")' 2>/dev/null)

      local inline_comments
      inline_comments=$(gh api "repos/$REPO/pulls/$pr_number/comments" \
        --jq '[.[] | "\(.path):\(.line // .original_line): \(.body)"] | join("\n")' 2>/dev/null)

      local has_feedback=false
      if [[ -n "$last_pr_comment" ]] && ! echo "$last_pr_comment" | grep -qF "$SOLVER_MARKER"; then
        has_feedback=true
      fi
      [[ -n "$review_bodies" ]] && has_feedback=true
      [[ -n "$inline_comments" ]] && has_feedback=true

      if [[ "$has_feedback" == "true" ]]; then
        echo "[solver] Human feedback on PR #$pr_number for issue #$number — retrying"

        set_issue_status "$number" "In Progress" "in-progress"

        local pr_comments_text
        pr_comments_text=$(gh pr view "$pr_number" --repo "$REPO" --json comments \
          --jq "[.comments[] | select(.body | contains(\"$SOLVER_MARKER\") | not) | .body] | join(\"\n---\n\")" 2>/dev/null)

        # Ensure clone exists
        if [[ ! -d "$clone_dir" ]]; then
          git clone --reference "$REPO_DIR" "$(git -C "$REPO_DIR" remote get-url origin)" "$clone_dir" 2>/dev/null
          git -C "$clone_dir" checkout "$branch" 2>/dev/null || true
        fi
        git -C "$clone_dir" pull origin "$branch" 2>/dev/null || true

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
2. Address ALL reviewer feedback above.
3. Make sure the code compiles/runs without errors or warnings.
4. Commit your fixes with a descriptive message.
5. Do NOT push — the automation will handle pushing.
RETRY_EOF
)

        local claude_log="$LOG_DIR/issue-${number}.log"
        : > "$claude_log"
        local claude_exit=0
        (cd "$clone_dir" && echo "$retry_prompt" | claude --model "$CLAUDE_MODEL" --output-format stream-json --verbose -p >> "$claude_log" 2>&1) || claude_exit=$?

        local retry_gist
        retry_gist=$(upload_execution_log "$LOG_DIR" "$number" "solver" "retry")
        local retry_log_link=""
        [[ -n "$retry_gist" ]] && retry_log_link="

---
[execution log]($retry_gist)"

        if [[ "$claude_exit" -ne 0 ]]; then
          echo "[solver] Claude retry failed for #$number (exit $claude_exit)"
          gh pr comment "$pr_number" --repo "$REPO" --body "${SOLVER_MARKER}
Retry failed: claude exited with code $claude_exit${retry_log_link}"
          set_issue_status "$number" "In Review" "in-review"
          continue
        fi

        git -C "$clone_dir" push origin "$branch" 2>/dev/null || {
          git -C "$clone_dir" push origin "$branch" --force-with-lease 2>/dev/null || true
        }

        gh pr comment "$pr_number" --repo "$REPO" --body "${SOLVER_MARKER}
Feedback addressed. Please re-review.${retry_log_link}"

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

while true; do
  echo ""
  find "$LOCK_DIR" -name "solver-issue-*" -type d -exec rmdir {} + 2>/dev/null || true

  echo "[solver] Polling at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # --- TODO issues (parallel) ---
  approved=$(get_approved_issues)
  approved_count=$(echo "$approved" | jq 'length')
  echo "[solver] Found $approved_count TODO issue(s)"

  # Fetch once before parallel processing
  if [[ "$approved_count" -gt 0 ]]; then
    git -C "$REPO_DIR" fetch origin 2>/dev/null
  fi

  running=0
  echo "$approved" | jq -c '.[]' | while IFS= read -r item; do
    number=$(echo "$item" | jq -r '.number')
    title=$(echo "$item" | jq -r '.title')
    body=$(echo "$item" | jq -r '.body')
    comments_json=$(echo "$item" | jq -c '.comments')

    echo "[solver] Starting issue #$number — $title"
    solve_issue "$number" "$title" "$body" "$comments_json" &
    running=$((running + 1))
    if [[ "$running" -ge "$SOLVER_PARALLEL" ]]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done
  wait

  # --- Stale check ---
  in_progress=$(get_in_progress_issues)
  in_progress_count=$(echo "$in_progress" | jq 'length')
  if [[ "$in_progress_count" -gt 0 ]]; then
    echo "[solver] Checking $in_progress_count in-progress issue(s)"
    echo "$in_progress" | jq -c '.[]' | while read -r issue; do
      check_stale "$(echo "$issue" | jq -r '.number')"
    done
  fi

  # --- Review check ---
  check_reviews

  echo "[solver] Sleeping ${SOLVER_INTERVAL}s..."
  sleep "$SOLVER_INTERVAL"
done
