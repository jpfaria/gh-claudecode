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
REFINER_INTERVAL="${REFINER_INTERVAL:-300}"
REFINER_PARALLEL="${REFINER_PARALLEL:-5}"
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
    --parallel)
      REFINER_PARALLEL="$2"
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

# Normalize REPO to owner/repo format
REPO=$(normalize_repo "$REPO")

# Check dependencies
for cmd in gh claude jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[refiner] Error: '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# Print startup message
echo "[refiner] Starting for $REPO (interval: ${REFINER_INTERVAL}s, parallel: ${REFINER_PARALLEL}, model: $CLAUDE_MODEL)"

# ---------------------------------------------------------------------------
# Load refiner skill + project context
# ---------------------------------------------------------------------------

REFINER_SKILL=""
if [[ -f "$SCRIPT_DIR/skills/refiner-interview.md" ]]; then
  REFINER_SKILL=$(cat "$SCRIPT_DIR/skills/refiner-interview.md")
  echo "[refiner] Loaded interview skill"
fi

REPO_CONTEXT=""
fetch_repo_file() {
  local path="$1"
  gh api "repos/$REPO/contents/$path" -q '.content' 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

echo "[refiner] Loading project context from $REPO..."
claude_md=$(fetch_repo_file "CLAUDE.md")
if [[ -n "$claude_md" ]]; then
  REPO_CONTEXT="## Project Context (CLAUDE.md)
${claude_md}"
  echo "[refiner] Loaded CLAUDE.md"
else
  echo "[refiner] Warning: no CLAUDE.md found in $REPO"
fi

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

# Get new issues: no board status and no workflow labels
get_new_issues() {
  local skip_labels="refining ready approved in-progress done failed system"
  gh issue list --repo "$REPO" --state open --json number,title,labels --limit 100 \
    | jq --arg skip "$skip_labels" '
      ($skip | split(" ")) as $skip_list |
      [.[] | select(
        (.labels | map(.name) | map(select(. as $l | $skip_list | index($l))) | length) == 0
      ) | {number, title}]'
}

# Get issues being refined: board status = "Refining"
get_refining_issues() {
  get_issues_by_board_status "Refining"
}

# Perform initial refinement of a new issue using claude
start_refinement() {
  local number="$1"
  local title="$2"

  echo "[refiner] Starting refinement for issue #$number: $title"

  local body
  body=$(gh issue view "$number" --repo "$REPO" --json body -q '.body')

  local prompt
  prompt=$(cat <<PROMPT
## Your Skill (how to behave)

${REFINER_SKILL}

## Project Context (what the project is about)

${REPO_CONTEXT}

---

## Current Task

This is a NEW issue that just arrived. Start the interview.

Issue #$number: $title

Issue body:
$body

---

Follow your skill instructions. Start gathering requirements from the user.
Reply ONLY with the comment text to be posted on the issue.
PROMPT
  )

  local response
  response=$(echo "$prompt" | claude --model "$CLAUDE_MODEL" -p 2>&1) || true

  if [[ -n "$response" ]]; then
    echo "[refiner] Got response from claude, posting comment on #$number"
    set_issue_status "$number" "Refining" "refining"
    gh issue comment "$number" --repo "$REPO" --body "${REFINER_MARKER}
${response}"
    echo "[refiner] Issue #$number labeled 'refining' and comment posted"
  else
    echo "[refiner] Error: empty response from claude for issue #$number" >&2
  fi
}

REFINER_MARKER="<!-- gh-claudecode:refiner -->"

# Check if the last comment on an issue was made by a human (not the refiner)
# Returns 0 (true) if human replied, 1 (false) if no interaction or refiner was last
last_comment_is_human() {
  local number="$1"

  # Check if refiner ever commented on this issue
  local has_refiner_comment
  has_refiner_comment=$(gh issue view "$number" --repo "$REPO" --json comments \
    -q "[.comments[].body | select(contains(\"$REFINER_MARKER\"))] | length")

  # Refiner never commented → skip (issue was placed in Refining manually)
  if [[ "$has_refiner_comment" -eq 0 ]]; then
    return 1
  fi

  local last_body
  last_body=$(gh issue view "$number" --repo "$REPO" --json comments \
    -q '.comments[-1].body // empty')

  # If last comment contains our marker → not human
  if echo "$last_body" | grep -qF "$REFINER_MARKER"; then
    return 1
  fi

  return 0
}

# Continue refinement of an issue: either complete the checklist or ask more questions
continue_refinement() {
  local number="$1"

  echo "[refiner] Continuing refinement for issue #$number"

  local issue_json
  issue_json=$(gh issue view "$number" --repo "$REPO" --json title,body,comments)

  local title body comments
  title=$(echo "$issue_json" | jq -r '.title')
  body=$(echo "$issue_json" | jq -r '.body')
  comments=$(echo "$issue_json" | jq -r '[.comments[-20:][].body] | join("\n\n---\n\n")')

  local prompt
  prompt=$(cat <<PROMPT
## Your Skill (how to behave)

${REFINER_SKILL}

## Project Context (what the project is about)

${REPO_CONTEXT}

---

## Current Task

This is an ONGOING conversation. The user has replied. Continue the interview.

Issue #$number: $title

Issue body:
$body

Recent comments:
$comments

---

Follow your skill instructions. Check if all functional requirements are clear.

If ANY are missing: reply with a follow-up question (following your skill rules).

If ALL are clear: assemble the full specification and respond with the CHECKLIST_COMPLETE block as defined in your skill. Include the technical section (you infer it from project knowledge).

Reply ONLY with the comment text (if still interviewing) or the CHECKLIST_COMPLETE block (if done).
PROMPT
  )

  local response
  response=$(echo "$prompt" | claude --model "$CLAUDE_MODEL" -p 2>&1) || true

  if [[ -z "$response" ]]; then
    echo "[refiner] Error: empty response from claude for issue #$number" >&2
    return
  fi

  local first_line
  first_line=$(echo "$response" | head -n1)

  if [[ "$first_line" == "CHECKLIST_COMPLETE" ]]; then
    echo "[refiner] Checklist complete for issue #$number, transitioning to ready"

    # Extract checklist (everything after the first ---)
    local checklist
    checklist=$(echo "$response" | sed '1,/^---$/d')

    # Append checklist to issue body
    local new_body
    new_body="${body}

---

## Refinement Checklist

${checklist}"

    gh issue edit "$number" --repo "$REPO" --body "$new_body"
    set_issue_status "$number" "Ready" "ready" "refining"
    gh issue comment "$number" --repo "$REPO" --body "${REFINER_MARKER}
Refinement complete. All checklist items have been filled. This issue is now **ready** for development."
    echo "[refiner] Issue #$number is now ready"
  else
    echo "[refiner] Posting follow-up questions on issue #$number"
    gh issue comment "$number" --repo "$REPO" --body "${REFINER_MARKER}
${response}"
  fi
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

ensure_labels "$REPO"
init_project_board || true

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------

while true; do
  echo ""
  echo "[refiner] Polling at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # --- New issues (no labels) ---
  new_issues=$(get_new_issues)
  new_count=$(echo "$new_issues" | jq 'length')
  echo "[refiner] Found $new_count new issue(s)"

  running=0
  echo "$new_issues" | jq -c '.[]' | while read -r item; do
    number=$(echo "$item" | jq -r '.number')
    title=$(echo "$item" | jq -r '.title')
    start_refinement "$number" "$title" &
    running=$((running + 1))
    if [[ "$running" -ge "$REFINER_PARALLEL" ]]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done
  wait

  # --- Refining issues ---
  refining_issues=$(get_refining_issues)
  refining_count=$(echo "$refining_issues" | jq 'length')
  echo "[refiner] Found $refining_count refining issue(s)"

  running=0
  echo "$refining_issues" | jq -c '.[]' | while read -r item; do
    number=$(echo "$item" | jq -r '.number')
    if last_comment_is_human "$number"; then
      continue_refinement "$number" &
      running=$((running + 1))
      if [[ "$running" -ge "$REFINER_PARALLEL" ]]; then
        wait -n 2>/dev/null || wait
        running=$((running - 1))
      fi
    else
      echo "[refiner] Skipping #$number — waiting for human response"
    fi
  done
  wait

  echo "[refiner] Sleeping ${REFINER_INTERVAL}s..."
  sleep "$REFINER_INTERVAL"
done
