#!/bin/bash
# Stage all changes and commit locally. Does NOT push.
# Usage: bash scripts/commit.sh "your commit message"
# Note: iOS git index.lock is held by Xcode when the project is open.
# If this fails, close Xcode first or use scripts/push.command which handles both.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

if [ -z "$1" ]; then
  echo "Usage: bash scripts/commit.sh \"commit message\""
  exit 1
fi

rm -f .git/index.lock .git/HEAD.lock 2>/dev/null || true
if [ -f .git/index.lock ] || [ -f .git/HEAD.lock ]; then
  echo "⚠️  Git lock files exist (likely held by Xcode). Close Xcode or run"
  echo "   scripts/push.command on your Mac instead."
  exit 1
fi
git config user.email "apbeers@icloud.com"
git config user.name "Andrew"
git --no-optional-locks add -A
git --no-optional-locks commit -m "$1"
echo ""
echo "Committed: $(git --no-optional-locks rev-parse --short HEAD) — $1"
echo "Run scripts/push.command to push to GitHub."
