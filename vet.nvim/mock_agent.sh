#!/usr/bin/env bash
# mock_agent.sh — simulates an AI coding CLI (stand-in for aider/claude-code/codex/etc).
# Usage: mock_agent.sh <prompt> <file>
# It "reads" the prompt and deterministically appends a multiply() function,
# mimicking what a real agent would do after editing the file in place.
set -euo pipefail

PROMPT="$1"
FILE="$2"

echo "[mock-agent] received instruction: $PROMPT"
echo "[mock-agent] editing file: $FILE"
sleep 1  # simulate thinking time

cat >> "$FILE" <<'EOF'


def multiply(a, b):
    return a * b
EOF

echo "[mock-agent] done."
