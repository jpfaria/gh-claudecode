#!/usr/bin/env bash
set -euo pipefail

# Load .env file if it exists (from script directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

# Default values
REPO="${REPO:-}"
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

# Check dependencies
for cmd in gh claude jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[solver] Error: '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Clone or update repo
# ---------------------------------------------------------------------------

mkdir -p "$WORKTREE_DIR"

REPO_DIR="$WORKTREE_DIR/_repo"

if [[ ! -d "$REPO_DIR" ]]; then
  echo "[solver] Cloning $REPO into $REPO_DIR"
  gh repo clone "$REPO" "$REPO_DIR"
else
  echo "[solver] Updating existing repo in $REPO_DIR"
  git -C "$REPO_DIR" fetch origin

  # Checkout develop if it exists, otherwise fall back to main
  if git -C "$REPO_DIR" rev-parse --verify origin/develop &>/dev/null; then
    git -C "$REPO_DIR" checkout develop
    git -C "$REPO_DIR" pull origin develop
  else
    git -C "$REPO_DIR" checkout main
    git -C "$REPO_DIR" pull origin main
  fi
fi

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

get_approved_issues() {
  gh issue list --repo "$REPO" --state open --label approved --json number,title
}

get_in_progress_issues() {
  gh issue list --repo "$REPO" --state open --label in-progress --json number,title
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

echo "[solver] Starting for $REPO (interval: ${SOLVER_INTERVAL}s, timeout: ${SOLVER_TIMEOUT}s, model: $CLAUDE_MODEL)"

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

  # TODO (Task 6): check for stale in-progress issues that exceeded SOLVER_TIMEOUT
  # and mark them as failed

  # --- Approved issues (pick first one, sequential) ---
  approved=$(get_approved_issues)
  approved_count=$(echo "$approved" | jq 'length')
  echo "[solver] Found $approved_count approved issue(s)"

  if [[ "$approved_count" -gt 0 ]]; then
    first=$(echo "$approved" | jq -c '.[0]')
    number=$(echo "$first" | jq -r '.number')
    title=$(echo "$first" | jq -r '.title')
    echo "[solver] Next issue to solve: #$number — $title"

    # TODO (Task 7): solve the issue (worktree, branch, claude, PR)
  fi

  echo "[solver] Sleeping ${SOLVER_INTERVAL}s..."
  sleep "$SOLVER_INTERVAL"
done
