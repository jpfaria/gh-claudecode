#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

REPO="${REPO:-}"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Error: --repo is required (e.g. --repo owner/repo)"
  exit 1
fi

echo "=== gh-claudecode setup ==="
echo "Target repo: $REPO"
echo ""

# 1. Check dependencies
echo "--- Checking dependencies ---"
for cmd in gh claude jq git; do
  if command -v "$cmd" &>/dev/null; then
    echo "  ✓ $cmd found: $(command -v "$cmd")"
  else
    echo "  ✗ $cmd NOT FOUND"
    echo ""
    case "$cmd" in
      gh)     echo "  Install: brew install gh (macOS) or https://github.com/cli/cli#installation" ;;
      claude) echo "  Install: npm install -g @anthropic-ai/claude-code" ;;
      jq)     echo "  Install: brew install jq (macOS) or sudo apt install jq" ;;
      git)    echo "  Install: brew install git (macOS) or sudo apt install git" ;;
    esac
    exit 1
  fi
done
echo ""

# 2. Check gh authentication
echo "--- Checking GitHub authentication ---"
if gh auth status &>/dev/null; then
  echo "  ✓ GitHub CLI authenticated"
  echo "  User: $(gh api user -q '.login')"
else
  echo "  ✗ GitHub CLI NOT authenticated"
  echo ""
  echo "  Run: gh auth login"
  exit 1
fi
echo ""

# 3. Check repo access
echo "--- Checking repo access ---"
if gh repo view "$REPO" --json name &>/dev/null; then
  echo "  ✓ Repo $REPO is accessible"
else
  echo "  ✗ Cannot access $REPO"
  echo ""
  echo "  Check: is the repo name correct? Do you have access?"
  echo "  If scopes are missing: gh auth refresh -s repo,project,read:org"
  exit 1
fi
echo ""

# 4. Check claude authentication
echo "--- Checking Claude Code ---"
if echo "ping" | claude -p &>/dev/null; then
  echo "  ✓ Claude Code responding"
else
  echo "  ✗ Claude Code not responding"
  echo ""
  echo "  Run: claude (to authenticate)"
  echo "  Or set: export ANTHROPIC_API_KEY=\"sk-ant-...\""
  exit 1
fi
echo ""

# 5. Create labels
echo "--- Setting up labels ---"

declare -A LABEL_COLORS=(
  [refining]="0E8A16"
  [ready]="1D76DB"
  [approved]="5319E7"
  [in-progress]="FBCA04"
  [done]="0E8A16"
  [failed]="D93F0B"
)

declare -A LABEL_DESCRIPTIONS=(
  [refining]="Refiner is interacting with human"
  [ready]="Checklist complete, awaiting approval"
  [approved]="Approved for implementation"
  [in-progress]="Solver is working on it"
  [done]="PR created"
  [failed]="Solver timed out or failed"
)

existing_labels=$(gh label list --repo "$REPO" --json name -q ".[].name")

for label in refining ready approved in-progress done failed; do
  if echo "$existing_labels" | grep -qx "$label"; then
    echo "  ✓ Label '$label' already exists"
  else
    gh label create "$label" --repo "$REPO" \
      --color "${LABEL_COLORS[$label]}" \
      --description "${LABEL_DESCRIPTIONS[$label]}"
    echo "  ✓ Label '$label' created"
  fi
done
echo ""

# 6. Summary
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Copy config:  cp config.example .env && vim .env"
echo "  2. Run refiner:  ./refiner.sh --repo $REPO"
echo "  3. Run solver:   ./solver.sh --repo $REPO"
echo ""
echo "Create an issue in $REPO to test the refiner!"
