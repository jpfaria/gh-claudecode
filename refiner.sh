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
REFINER_INTERVAL="${REFINER_INTERVAL:-300}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --interval)
      REFINER_INTERVAL="$2"
      shift 2
      ;;
    --model)
      CLAUDE_MODEL="$2"
      shift 2
      ;;
    *)
      echo "[refiner] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Validate --repo is provided
if [[ -z "$REPO" ]]; then
  echo "[refiner] Error: --repo is required" >&2
  exit 1
fi

# Check dependencies
for cmd in gh claude jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[refiner] Error: '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# Print startup message
echo "[refiner] Starting for $REPO (interval: ${REFINER_INTERVAL}s, model: $CLAUDE_MODEL)"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

# Ensure the 6 workflow labels exist in the target repo
ensure_labels() {
  local repo="$1"
  local label color
  local pairs="refining:fbca04 ready:0e8a16 approved:1d76db in-progress:d93f0b done:0e8a16 failed:b60205"
  local existing
  existing=$(gh label list --repo "$repo" --json name -q ".[].name")

  for pair in $pairs; do
    label="${pair%%:*}"
    color="${pair##*:}"
    if ! echo "$existing" | grep -qx "$label"; then
      echo "[refiner] Creating label '$label' in $repo"
      gh label create "$label" --repo "$repo" --color "$color" --description "Auto-created by refiner" || true
    fi
  done
  echo "[refiner] All required labels verified"
}

# Return open issues with NO labels (new, unprocessed issues)
get_new_issues() {
  local repo="$1"
  gh issue list --repo "$repo" --state open --json number,title,labels \
    | jq '[.[] | select(.labels | length == 0)]'
}

# Return open issues with label "refining"
get_refining_issues() {
  local repo="$1"
  gh issue list --repo "$repo" --state open --label "refining" --json number,title
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

ensure_labels "$REPO"

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

while true; do
  echo ""
  echo "[refiner] Polling at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # --- New issues (no labels) ---
  new_issues=$(get_new_issues "$REPO")
  new_count=$(echo "$new_issues" | jq 'length')
  echo "[refiner] Found $new_count new issue(s)"

  echo "$new_issues" | jq -c '.[]' | while read -r item; do
    number=$(echo "$item" | jq -r '.number')
    title=$(echo "$item" | jq -r '.title')
    echo "[refiner] Processing new issue #$number: $title"
  done

  # --- Refining issues ---
  refining_issues=$(get_refining_issues "$REPO")
  refining_count=$(echo "$refining_issues" | jq 'length')
  echo "[refiner] Found $refining_count refining issue(s)"

  echo "$refining_issues" | jq -c '.[]' | while read -r item; do
    number=$(echo "$item" | jq -r '.number')
    echo "[refiner] Checking issue #$number for human response"
  done

  echo "[refiner] Sleeping ${REFINER_INTERVAL}s..."
  sleep "$REFINER_INTERVAL"
done
