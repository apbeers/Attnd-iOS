#!/bin/bash
# Show repo state. Safe to run from the agent's bash sandbox.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
echo "=== Attnd-iOS ==="
echo "Branch : $(git rev-parse --abbrev-ref HEAD)"
echo "Commit : $(git log -1 --format='%h %s (%ar)')"
echo "Ahead  : $(git rev-list --count @{u}..HEAD 2>/dev/null || echo '?') commits not pushed"
echo ""
git --no-optional-locks status --short
