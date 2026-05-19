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

# Bump CURRENT_PROJECT_VERSION in project.pbxproj by 1
PBXPROJ="$REPO/Attnd.xcodeproj/project.pbxproj"
CURRENT=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | grep -o '[0-9]*')
NEXT=$((CURRENT + 1))
sed -i "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEXT;/g" "$PBXPROJ"
echo "Build $CURRENT → $NEXT"

bash "$REPO/scripts/commit.sh" "$1"
bash "$REPO/scripts/push.sh" "${2:-}"
