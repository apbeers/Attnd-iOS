#!/bin/bash
# Stage all changes, commit, and push in one step.
# Usage: bash scripts/commit_and_push.sh "your commit message" [branch]
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

if [ -z "$1" ]; then
  echo "Usage: bash scripts/commit_and_push.sh \"commit message\" [branch]"
  exit 1
fi

bash "$REPO/scripts/commit.sh" "$1"
bash "$REPO/scripts/push.sh" "${2:-}"
