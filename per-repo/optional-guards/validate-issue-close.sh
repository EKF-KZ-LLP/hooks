#!/bin/bash
# Validates that a GitHub Issue can be closed
# Run before: gh issue close <number>
set -euo pipefail

ISSUE_NUM="${1:?Usage: validate-issue-close.sh <issue_number>}"

echo "=== Validating Issue #$ISSUE_NUM for closure ==="

# Get issue body
BODY=$(gh issue view "$ISSUE_NUM" --json body -q .body 2>/dev/null)
if [[ -z "$BODY" ]]; then
  echo "❌ Cannot read Issue #$ISSUE_NUM"
  exit 1
fi

# Check DoD checkboxes - all must be checked
# BSD/GNU compatible: count lines matching unchecked checkbox pattern.
UNCHECKED=$(printf '%s\n' "$BODY" | grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' || true)
UNCHECKED=${UNCHECKED:-0}
if [[ "$UNCHECKED" -gt 0 ]]; then
  echo "FAIL $UNCHECKED unchecked DoD items in Issue #$ISSUE_NUM"
  echo "Complete all Definition of Done checkboxes before closing."
  echo ""
  echo "Unchecked items:"
  printf '%s\n' "$BODY" | grep -E '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]'
  exit 1
fi

# Check that "Результат" section is filled (matches the markdown heading the script greps for)
COMMENTS=$(gh issue view "$ISSUE_NUM" --json comments -q '.comments[].body' 2>/dev/null)
HAS_RESULT=$(printf '%s\n' "$COMMENTS" | grep -cE "## Результат|### Что сделано" || true)
HAS_RESULT=${HAS_RESULT:-0}
if [[ "$HAS_RESULT" -eq 0 ]]; then
  # Also check issue body
  HAS_RESULT_BODY=$(printf '%s\n' "$BODY" | grep -cE "### Что сделано" || true)
  HAS_RESULT_BODY=${HAS_RESULT_BODY:-0}
  if [[ "$HAS_RESULT_BODY" -eq 0 ]]; then
    echo "❌ No 'Результат' section found"
    echo "Add a closing comment with:"
    echo "  ## Результат"
    echo "  ### Что сделано"
    echo "  - ..."
    echo "  ### Коммиты"
    echo "  - ..."
    exit 1
  fi
fi

echo "✅ Issue #$ISSUE_NUM ready to close"
echo "Run: gh issue close $ISSUE_NUM"
