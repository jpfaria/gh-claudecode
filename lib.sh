#!/usr/bin/env bash
# Shared functions for refiner and solver

# Normalize REPO to owner/repo format
normalize_repo() {
  local repo="$1"
  repo="${repo#git@github.com:}"
  repo="${repo#https://github.com/}"
  repo="${repo%.git}"
  echo "$repo"
}

# ---------------------------------------------------------------------------
# Project readiness check — run once at startup
# ---------------------------------------------------------------------------

# All required labels with colors
REQUIRED_LABELS="refining:fbca04 ready:0e8a16 approved:1d76db in-progress:d93f0b in-review:e4e669 done:0e8a16 failed:b60205 system:c5def5"

# All required board status options with colors
REQUIRED_STATUSES="Refining:ORANGE Ready:BLUE Approved:PURPLE In_Progress:YELLOW In_Review:PINK Done:GREEN Failed:RED"

ensure_project_ready() {
  local repo="$1"
  local owner="${repo%%/*}"

  echo "[lib] Ensuring project $repo is ready..."

  # --- 1. Verify repo access ---
  if ! gh repo view "$repo" --json name &>/dev/null; then
    echo "[lib] Error: cannot access repo $repo" >&2
    return 1
  fi
  echo "[lib] ✓ Repo accessible"

  # --- 2. Verify gitflow (main + develop branches) ---
  local has_main has_develop
  has_main=$(gh api "repos/$repo/branches/main" --jq '.name' 2>/dev/null || echo "")
  has_develop=$(gh api "repos/$repo/branches/develop" --jq '.name' 2>/dev/null || echo "")

  if [[ -z "$has_main" ]]; then
    echo "[lib] Warning: branch 'main' not found in $repo"
  else
    echo "[lib] ✓ Branch main exists"
  fi

  if [[ -z "$has_develop" ]]; then
    echo "[lib] Warning: branch 'develop' not found in $repo — solver will use main as base"
  else
    echo "[lib] ✓ Branch develop exists"
  fi

  # --- 3. Ensure labels ---
  local existing_labels
  existing_labels=$(gh label list --repo "$repo" --json name -q ".[].name" 2>/dev/null)

  local label_descriptions="refining:Refiner is interacting with human ready:Checklist complete, awaiting approval approved:Approved for implementation in-progress:Solver is working on it in-review:PR created, awaiting review done:PR merged failed:Solver timed out or failed system:System-generated issue"

  for pair in $REQUIRED_LABELS; do
    local label="${pair%%:*}"
    local color="${pair##*:}"
    if ! echo "$existing_labels" | grep -qx "$label"; then
      gh label create "$label" --repo "$repo" --color "$color" --description "Auto-created by gh-claudecode" 2>/dev/null || true
      echo "[lib] ✓ Created label '$label'"
    fi
  done
  echo "[lib] ✓ All labels verified"

  # --- 4. Ensure Project Board statuses ---
  local project_number="${PROJECT_NUMBER:-1}"
  local project_json
  project_json=$(gh api graphql -f query="
  {
    user(login: \"$owner\") {
      projectV2(number: $project_number) {
        id
        fields(first: 20) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }
          }
        }
      }
    }
  }" 2>/dev/null) || true

  if [[ -z "$project_json" ]] || ! echo "$project_json" | jq empty 2>/dev/null; then
    echo "[lib] Warning: could not access Project Board #$project_number — board sync disabled"
    return 0
  fi

  local project_id
  project_id=$(echo "$project_json" | jq -r '.data.user.projectV2.id // empty')
  if [[ -z "$project_id" ]]; then
    echo "[lib] Warning: Project Board #$project_number not found"
    return 0
  fi

  local status_field_id
  status_field_id=$(echo "$project_json" | jq -r '.data.user.projectV2.fields.nodes[] | select(.name == "Status") | .id // empty')

  local existing_statuses
  existing_statuses=$(echo "$project_json" | jq -r '.data.user.projectV2.fields.nodes[] | select(.name == "Status") | [.options[].name] | join(",")')

  # Check if all required statuses exist
  local missing=false
  for pair in $REQUIRED_STATUSES; do
    local status_name="${pair%%:*}"
    status_name="${status_name//_/ }"
    if ! echo ",$existing_statuses," | grep -qF ",$status_name,"; then
      missing=true
      echo "[lib] Missing board status: $status_name"
    fi
  done

  if [[ "$missing" == "true" ]] && [[ -n "$status_field_id" ]]; then
    echo "[lib] Creating missing board statuses..."
    # Build full options list
    local options_json="["
    local first=true
    for pair in $REQUIRED_STATUSES; do
      local status_name="${pair%%:*}"
      local status_color="${pair##*:}"
      status_name="${status_name//_/ }"
      if [[ "$first" == "true" ]]; then first=false; else options_json+=","; fi
      options_json+="{ \"name\": \"$status_name\", \"color\": \"$status_color\", \"description\": \"\" }"
    done
    options_json+="]"

    gh api graphql -f query="
    mutation {
      updateProjectV2Field(input: {
        fieldId: \"$status_field_id\"
        singleSelectOptions: $options_json
      }) {
        projectV2Field {
          ... on ProjectV2SingleSelectField {
            options { id name }
          }
        }
      }
    }" >/dev/null 2>&1 && echo "[lib] ✓ Board statuses updated" || echo "[lib] Warning: could not update board statuses"
  else
    echo "[lib] ✓ All board statuses verified"
  fi

  echo "[lib] Project $repo is ready"
}

# ---------------------------------------------------------------------------
# Project Board sync
# ---------------------------------------------------------------------------

# Cache project metadata (called once at startup)
# Sets: PROJECT_ID, STATUS_FIELD_ID, STATUS_OPTIONS (associative-like)
PROJECT_ID=""
STATUS_FIELD_ID=""
STATUS_OPTION_IDS=""

init_project_board() {
  local owner="${REPO%%/*}"
  local project_number="${PROJECT_NUMBER:-1}"

  echo "[lib] Loading project board for $owner #$project_number..."

  local result
  result=$(gh api graphql -f query="
  {
    user(login: \"$owner\") {
      projectV2(number: $project_number) {
        id
        fields(first: 20) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  }" 2>/dev/null) || {
    echo "[lib] Warning: could not load project board (missing scope or project not found)"
    return 1
  }

  PROJECT_ID=$(echo "$result" | jq -r '.data.user.projectV2.id // empty')
  if [[ -z "$PROJECT_ID" ]]; then
    echo "[lib] Warning: project board not found"
    return 1
  fi

  STATUS_FIELD_ID=$(echo "$result" | jq -r '.data.user.projectV2.fields.nodes[] | select(.name == "Status") | .id // empty')
  if [[ -z "$STATUS_FIELD_ID" ]]; then
    echo "[lib] Warning: Status field not found in project board"
    return 1
  fi

  # Build option ID lookup: "label_name:option_id" pairs
  STATUS_OPTION_IDS=$(echo "$result" | jq -r '.data.user.projectV2.fields.nodes[] | select(.name == "Status") | .options[] | "\(.name):\(.id)"')

  echo "[lib] Project board loaded ($(echo "$STATUS_OPTION_IDS" | wc -l | tr -d ' ') status options)"
  return 0
}

# Get the project item ID for a given issue number
get_project_item_id() {
  local issue_number="$1"
  local owner="${REPO%%/*}"
  local project_number="${PROJECT_NUMBER:-1}"

  gh api graphql -f query="
  {
    user(login: \"$owner\") {
      projectV2(number: $project_number) {
        items(first: 100) {
          nodes {
            id
            content {
              ... on Issue {
                number
              }
            }
          }
        }
      }
    }
  }" 2>/dev/null | jq -r ".data.user.projectV2.items.nodes[] | select(.content.number == $issue_number) | .id // empty"
}

# Add issue to project if not already there
add_issue_to_project() {
  local issue_number="$1"
  local repo="$REPO"

  # Get issue node ID
  local issue_node_id
  issue_node_id=$(gh issue view "$issue_number" --repo "$repo" --json id -q '.id' 2>/dev/null)

  if [[ -z "$issue_node_id" ]]; then
    echo "[lib] Warning: could not get node ID for issue #$issue_number"
    return 1
  fi

  local item_id
  item_id=$(gh api graphql -f query="
  mutation {
    addProjectV2ItemById(input: {
      projectId: \"$PROJECT_ID\"
      contentId: \"$issue_node_id\"
    }) {
      item {
        id
      }
    }
  }" 2>/dev/null | jq -r '.data.addProjectV2ItemById.item.id // empty')

  echo "$item_id"
}

# Set the Status field on a project item
# Usage: set_project_status <issue_number> <status_name>
# status_name: "New", "Refining", "Ready", "Approved", "In Progress", "Done", "Failed"
set_project_status() {
  local issue_number="$1"
  local status_name="$2"

  if [[ -z "$PROJECT_ID" ]] || [[ -z "$STATUS_FIELD_ID" ]]; then
    return 0  # silently skip if project board not initialized
  fi

  # Find option ID for this status
  local option_id
  option_id=$(echo "$STATUS_OPTION_IDS" | grep "^${status_name}:" | cut -d: -f2)

  if [[ -z "$option_id" ]]; then
    echo "[lib] Warning: status '$status_name' not found in project board"
    return 1
  fi

  # Get or create project item
  local item_id
  item_id=$(get_project_item_id "$issue_number")

  if [[ -z "$item_id" ]]; then
    item_id=$(add_issue_to_project "$issue_number")
    if [[ -z "$item_id" ]]; then
      echo "[lib] Warning: could not add issue #$issue_number to project"
      return 1
    fi
  fi

  # Update status
  gh api graphql -f query="
  mutation {
    updateProjectV2ItemFieldValue(input: {
      projectId: \"$PROJECT_ID\"
      itemId: \"$item_id\"
      fieldId: \"$STATUS_FIELD_ID\"
      value: { singleSelectOptionId: \"$option_id\" }
    }) {
      projectV2Item {
        id
      }
    }
  }" >/dev/null 2>&1 || {
    echo "[lib] Warning: could not update project status for issue #$issue_number"
    return 1
  }

  echo "[lib] Issue #$issue_number → $status_name"
}

# Get issues from the Project Board by status name
# Usage: get_issues_by_board_status "Refining"
# Returns JSON array: [{"number": 1, "title": "...", "item_id": "..."}]
get_issues_by_board_status() {
  local target_status="$1"
  local owner="${REPO%%/*}"
  local project_number="${PROJECT_NUMBER:-1}"

  if [[ -z "$PROJECT_ID" ]]; then
    echo "[]"
    return
  fi

  local raw
  raw=$(gh api graphql -f query="
  {
    user(login: \"$owner\") {
      projectV2(number: $project_number) {
        items(first: 100) {
          nodes {
            id
            fieldValueByName(name: \"Status\") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
              }
            }
            content {
              ... on Issue {
                number
                title
                state
              }
            }
          }
        }
      }
    }
  }" 2>&1) || true

  if ! echo "$raw" | jq empty 2>/dev/null; then
    echo "[lib] Warning: GraphQL error in get_issues_by_board_status: $(echo "$raw" | head -1)" >&2
    echo "[]"
    return
  fi

  echo "$raw" | jq --arg status "$target_status" '
    [.data.user.projectV2.items.nodes[]
     | select(.fieldValueByName.name == $status)
     | select(.content.state == "OPEN")
     | {number: .content.number, title: .content.title, item_id: .id}]'
}

# Get issues from board with comments included (single query, avoids N+1)
# Usage: get_issues_by_board_status_with_comments "Refining"
# Returns JSON array with number, title, item_id, comments (last 5 bodies)
get_issues_by_board_status_with_comments() {
  local target_status="$1"
  local owner="${REPO%%/*}"
  local repo_name="${REPO##*/}"
  local project_number="${PROJECT_NUMBER:-1}"

  if [[ -z "$PROJECT_ID" ]]; then
    echo "[]"
    return
  fi

  local raw
  raw=$(gh api graphql -f query="
  {
    user(login: \"$owner\") {
      projectV2(number: $project_number) {
        items(first: 100) {
          nodes {
            id
            fieldValueByName(name: \"Status\") {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
              }
            }
            content {
              ... on Issue {
                number
                title
                state
                body
                comments(last: 20) {
                  nodes {
                    body
                  }
                }
              }
            }
          }
        }
      }
    }
  }" 2>&1) || true

  if ! echo "$raw" | jq empty 2>/dev/null; then
    echo "[lib] Warning: GraphQL error in get_issues_by_board_status_with_comments: $(echo "$raw" | head -1)" >&2
    echo "[]"
    return
  fi

  echo "$raw" | jq --arg status "$target_status" '
    [.data.user.projectV2.items.nodes[]
     | select(.fieldValueByName.name == $status)
     | select(.content.state == "OPEN")
     | {
         number: .content.number,
         title: .content.title,
         body: .content.body,
         item_id: .id,
         comments: [.content.comments.nodes[].body],
         last_comment: (.content.comments.nodes[-1].body // ""),
         has_comments: (.content.comments.nodes | length > 0)
       }]'
}

# All workflow labels (used for cleanup)
ALL_WORKFLOW_LABELS="refining ready approved in-progress in-review done failed"

# Set both board status AND label in one call
# Removes ALL other workflow labels before adding the new one
# Usage: set_issue_status <issue_number> <status_name> <label_name>
set_issue_status() {
  local issue_number="$1"
  local board_status="$2"
  local label="$3"

  # Update board
  set_project_status "$issue_number" "$board_status"

  # Remove all workflow labels, then add the new one
  for old in $ALL_WORKFLOW_LABELS; do
    if [[ "$old" != "$label" ]]; then
      gh issue edit "$issue_number" --repo "$REPO" --remove-label "$old" 2>/dev/null || true
    fi
  done
  gh issue edit "$issue_number" --repo "$REPO" --add-label "$label" 2>/dev/null || true
}
