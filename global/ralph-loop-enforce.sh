#!/usr/bin/env bash
# Shared Task Evidence Contract and Ralph Loop enforcement hook.
# Wire as PreToolUse for Edit, Write and MultiEdit.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_dir/ralph-loop-validate.py"

if [ ! -x "$validator" ]; then
  echo "::error::ralph-loop-enforce: missing executable validator at $validator" >&2
  exit 2
fi

exec python3 "$validator" pretool
