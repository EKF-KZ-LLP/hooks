#!/usr/bin/env bash
# Global hook: block writing files with hardcoded secrets.
# Works on ALL projects + ALL 3 mutation tools (Write/Edit/MultiEdit).
#
# Codex review fixes applied:
#   round 7: read tool_input.{content,new_string,edits[].new_string} - covers Write/Edit/MultiEdit.
#   round 8: ignore old_string in match - removal of existing secret allowed.
#   round 9: NEVER print matched-text in logs (even partial). Classifier-only.
#            Whitelist env/template placeholders so $VAR / ${VAR} / {{x}} / <REPLACE_ME>
#            / os.environ / process.env / getenv / infisical / vault are NOT blocked.
#   round 10: whitelist applies ONLY to the low-confidence Generic
#             password/secret/api_key literal pattern. Comment-marker
#             keywords removed from whitelist.
#   round 11: whitelist check moved from LINE-level to VALUE-level.
#             Extract the quoted value and require it ENTIRELY equals
#             a placeholder format (^...$ anchored).
#   round 12: value extraction bound to the SPECIFIC matched key. Bash
#             regex with capture group extracts value paired with the
#             password/secret/api_key/access_token/client_secret key.
#             ALL key=value pairs on the line iterated.
#             Generic regex also accepts JSON-style "key":"value".
#   round 13: iterate ALL matched lines, not just head -1. Previously
#             multi-line Write where line 1 = placeholder and line 2 =
#             real secret slipped through because hook examined only
#             the first match.
set -uo pipefail

INPUT=$(cat)

# Aggregate ONLY post-edit content from mutation tool input shapes.
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
NEW_CONTENT=$(echo "$INPUT" | jq -r '
  [
    (.tool_input.content // empty),
    (.tool_input.new_string // empty),
    ((.tool_input.edits // []) | map(.new_string // empty) | join("\n"))
  ] | join("\n")
' 2>/dev/null)
OLD_CONTENT=$(echo "$INPUT" | jq -r '
  [
    (.tool_input.old_string // empty),
    ((.tool_input.edits // []) | map(.old_string // empty) | join("\n"))
  ] | join("\n")
' 2>/dev/null)

if [ -z "$NEW_CONTENT" ]; then
    exit 0
fi

# PATTERN_LIST: each entry = "classifier|regex". Classifier printed in log,
# regex actual matcher. Matched secret-text NEVER printed.
PATTERN_LIST=(
  'Anthropic API key (sk-ant-)|sk-ant-[A-Za-z0-9_-]{20,}'
  'OpenRouter API key (sk-or-)|sk-or-[A-Za-z0-9_-]{20,}'
  'OpenAI API key (sk-proj-)|sk-proj-[A-Za-z0-9_-]{20,}'
  'GitHub PAT classic (ghp_)|ghp_[A-Za-z0-9]{36,}'
  'GitHub PAT fine-grained|github_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{50,}'
  'GitHub OAuth user token (gho_)|gho_[A-Za-z0-9]{36,}'
  'GitHub server-to-server (ghs_)|ghs_[A-Za-z0-9]{36,}'
  'GitHub user-to-server (ghu_)|ghu_[A-Za-z0-9]{36,}'
  'GitLab PAT (glpat-)|glpat-[A-Za-z0-9_-]{20,}'
  'AWS Access Key ID (AKIA)|AKIA[A-Z0-9]{16}'
  'Google API key (AIza)|AIza[A-Za-z0-9_-]{35}'
  'Slack token (xox*)|xox[abprs]-[A-Za-z0-9-]{10,}-[A-Za-z0-9-]{10,}-[A-Za-z0-9-]{10,}'
  'Stripe/RevKey live or test|(sk|rk)_(live|test)_[A-Za-z0-9]{24,}'
  'JWT token (3-part eyJ...)|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  'PEM private key block|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
  'Authorization: Bearer <token>|[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}'
  'Generic password/secret/api_key literal|["'"'"']?(password|secret|api[_-]?key|access[_-]?token|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}["'"'"']'
  'AWS Secret Access Key (40-char + context)|(aws[_-]?secret[_-]?access[_-]?key|aws[_-]?secret|AWS[_-]?SECRET)[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+=]{40}["'"'"']?'
)

# Placeholder whitelist - ONLY STRUCTURAL env-ref / template markers.
# Comment-marker keywords (TODO, CHANGEME, EXAMPLE, REDACTED, X-fill) are
# DELIBERATELY EXCLUDED (Codex round 10): they can sit in a trailing
# comment of a line that ALSO carries a real secret value, and previously
# matched whitelist would have let the secret through.
#
# Whitelist only matches structural placeholder formats that REPLACE the
# value itself (cannot sit alongside a real secret in the same quoted
# string).
PLACEHOLDER_RE='\$[A-Z_][A-Z0-9_]*|\$\{[A-Z_][A-Z0-9_]*\}|\{\{[^}]+\}\}|<[A-Z_][A-Z0-9_]*>|<REPLACE[_-]?ME>|<YOUR[_-][A-Z_]+>|os\.environ|os\.getenv|process\.env|getenv\(|infisical\.|vault\.|Vault\.|SecretsManager|AWS_PROFILE'

match_classifier=""
old_has_real_secret=0

check_block() {
    local blob="$1" tag="$2"
    local cls re hit_lines
    for entry in "${PATTERN_LIST[@]}"; do
        cls="${entry%%|*}"
        re="${entry#*|}"
        # Get ALL matched lines, not just the first one. A multi-line
        # Write/Edit content can have placeholder pair на первой строке
        # и real secret на второй - head -1 ловит только первую и пропускает
        # secret (Codex round 13).
        hit_lines=$(echo "$blob" | grep -E "$re" 2>/dev/null)
        [ -n "$hit_lines" ] || continue

        # For high-confidence token-prefix patterns: ANY match = block.
        if [ "$cls" != "Generic password/secret/api_key literal" ]; then
            if [ "$tag" = "NEW" ]; then
                match_classifier="$cls"
                return 0
            else
                old_has_real_secret=1
                return 0
            fi
        fi

        # Generic pattern: VALUE-level whitelist applied per matched line.
        # If at least ONE matched line has a real (non-placeholder) value
        # for any key=value pair → block. ALL lines must be all-placeholder
        # to pass.
        local kv_re='["'"'"']?(password|secret|api[_-]?key|access[_-]?token|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']([^"'"'"']{8,})["'"'"']'
        local any_real_secret=0
        local any_pair_seen=0
        while IFS= read -r one_line; do
            [ -n "$one_line" ] || continue
            local remaining="$one_line"
            while [[ "$remaining" =~ $kv_re ]]; do
                any_pair_seen=1
                local val="${BASH_REMATCH[2]}"
                if ! echo "$val" | grep -qE "^(${PLACEHOLDER_RE})\$"; then
                    any_real_secret=1
                    break
                fi
                remaining="${remaining/"${BASH_REMATCH[0]}"/}"
            done
            if [ "$any_real_secret" = "1" ]; then
                break
            fi
        done <<< "$hit_lines"

        if [ "$any_pair_seen" = "1" ] && [ "$any_real_secret" = "0" ]; then
            # Every value across every matched line is a placeholder.
            continue
        fi
        if [ "$tag" = "NEW" ]; then
            match_classifier="$cls"
            return 0
        else
            old_has_real_secret=1
            return 0
        fi
    done
    return 1
}

check_block "$NEW_CONTENT" "NEW" || true
new_classifier="$match_classifier"

check_block "$OLD_CONTENT" "OLD" || true

if [ -z "$new_classifier" ]; then
    if [ "$old_has_real_secret" = "1" ]; then
        echo "::warning::guard-no-secrets: secret detected in OLD content but NOT in NEW; treating as removal, allowing edit." >&2
    fi
    exit 0
fi

echo "::error::guard-no-secrets: hardcoded secret detected in ${TOOL:-Write/Edit/MultiEdit} NEW content." >&2
echo "::error::Classifier: $new_classifier" >&2
echo "Use env-vars (\$VAR / \${VAR}), templates ({{x}} / <REPLACE_ME>), os.environ / process.env / getenv, or Infisical/Vault. NEVER commit raw tokens." >&2
echo "Note: removing an existing secret IS allowed - only adding/keeping one is blocked." >&2
exit 2
