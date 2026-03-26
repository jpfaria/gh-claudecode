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

# Perform initial refinement of a new issue using claude
start_refinement() {
  local number="$1"
  local title="$2"

  echo "[refiner] Starting refinement for issue #$number: $title"

  local body
  body=$(gh issue view "$number" --repo "$REPO" --json body -q '.body')

  local prompt
  prompt=$(cat <<PROMPT
You are a technical project manager analyzing a GitHub issue.

Issue #$number: $title

Issue body:
$body

---

Every issue must have the following checklist completed before development:

1. **Problem / objective described** — clear explanation of what and why
2. **Proposed solution** — high-level approach or architecture
3. **Affected files / modules** — which parts of the codebase are impacted
4. **Acceptance criteria** — concrete conditions to consider this done
5. **Type** — bug, feature, enhancement, refactor, docs, or chore
6. **Complexity estimate** — S, M, L, or XL

Analyze the issue text and determine which checklist items can already be filled from the existing content. For items that are missing or unclear, ask specific questions to the issue author.

Reply ONLY with the comment text to be posted on the issue. Be concise, use markdown formatting, and start with a greeting to the author.
PROMPT
  )

  local response
  response=$(echo "$prompt" | claude --model "$CLAUDE_MODEL" -p 2>&1) || true

  if [[ -n "$response" ]]; then
    echo "[refiner] Got response from claude, posting comment on #$number"
    gh issue edit "$number" --repo "$REPO" --add-label "refining"
    gh issue comment "$number" --repo "$REPO" --body "$response"
    echo "[refiner] Issue #$number labeled 'refining' and comment posted"
  else
    echo "[refiner] Error: empty response from claude for issue #$number" >&2
  fi
}

# Check if the last comment on an issue was made by a human (not us or a bot)
# Returns 0 (true) if human, 1 (false) if bot/ourselves
last_comment_is_human() {
  local number="$1"
  local my_login
  my_login=$(gh api user -q '.login')

  local last_author
  last_author=$(gh issue view "$number" --repo "$REPO" --json comments \
    -q '.comments[-1].author.login // empty')

  # No comments yet — treat as human (the body itself is from human)
  if [[ -z "$last_author" ]]; then
    return 0
  fi

  # If last comment is from us, a [bot], or github-actions → not human
  if [[ "$last_author" == "$my_login" ]] \
    || [[ "$last_author" == *"[bot]"* ]] \
    || [[ "$last_author" == "github-actions" ]]; then
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
You are a technical project manager refining a GitHub issue through conversation.

Issue #$number: $title

Issue body:
$body

Recent comments:
$comments

---

The following 6 checklist items are MANDATORY before this issue can move to development:

1. **Problem / objective described** — clear explanation of what and why
2. **Proposed solution** — high-level approach or architecture
3. **Affected files / modules** — which parts of the codebase are impacted
4. **Acceptance criteria** — concrete conditions to consider this done
5. **Type** — bug, feature, enhancement, refactor, docs, or chore
6. **Complexity estimate** — S, M, L, or XL

Analyze ALL content above (body + comments). If ALL 6 items can be confidently filled from the existing information, respond with EXACTLY:

CHECKLIST_COMPLETE
---
- [x] **Problem / objective described** — <filled summary>
- [x] **Proposed solution** — <filled summary>
- [x] **Affected files / modules** — <filled summary>
- [x] **Acceptance criteria** — <filled summary>
- [x] **Type** — <filled value>
- [x] **Complexity estimate** — <filled value>

If ANY items are still missing or unclear, respond ONLY with a follow-up comment asking specific questions to gather the missing information. Be concise and use markdown.
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
    gh issue edit "$number" --repo "$REPO" --remove-label "refining" --add-label "ready"
    gh issue comment "$number" --repo "$REPO" --body "Refinement complete. All checklist items have been filled. This issue is now **ready** for development."
    echo "[refiner] Issue #$number is now ready"
  else
    echo "[refiner] Posting follow-up questions on issue #$number"
    gh issue comment "$number" --repo "$REPO" --body "$response"
  fi
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
    start_refinement "$number" "$title"
  done

  # --- Refining issues ---
  refining_issues=$(get_refining_issues "$REPO")
  refining_count=$(echo "$refining_issues" | jq 'length')
  echo "[refiner] Found $refining_count refining issue(s)"

  echo "$refining_issues" | jq -c '.[]' | while read -r item; do
    number=$(echo "$item" | jq -r '.number')
    if last_comment_is_human "$number"; then
      continue_refinement "$number"
    else
      echo "[refiner] Skipping #$number — waiting for human response"
    fi
  done

  echo "[refiner] Sleeping ${REFINER_INTERVAL}s..."
  sleep "$REFINER_INTERVAL"
done
