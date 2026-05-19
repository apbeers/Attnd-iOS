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

# Bump build and version numbers in project.pbxproj
PBXPROJ="$REPO/Attnd.xcodeproj/project.pbxproj"
CURRENT=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBXPROJ" | grep -o '[0-9]*')
NEXT=$((CURRENT + 1))
sed -i.bak \
  -e "s/CURRENT_PROJECT_VERSION = $CURRENT;/CURRENT_PROJECT_VERSION = $NEXT;/g" \
  -e "s/MARKETING_VERSION = 1\.0\.$CURRENT;/MARKETING_VERSION = 1.0.$NEXT;/g" \
  "$PBXPROJ"
rm -f "$PBXPROJ.bak" 2>/dev/null || true
echo "Build $CURRENT → $NEXT  |  Version 1.0.$CURRENT → 1.0.$NEXT"

bash "$REPO/scripts/commit.sh" "$1"
bash "$REPO/scripts/push.sh" "${2:-}"
