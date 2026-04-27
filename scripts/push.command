#!/bin/bash
# Commit any pending changes and push to GitHub (develop branch).
# Double-click to run on your Mac. Handles the Xcode index.lock issue.
cd "$(dirname "$0")/.."
rm -f .git/index.lock .git/HEAD.lock

git config user.email "apbeers@icloud.com"
git config user.name "Andrew"
git add -A

PENDING=$(git diff --cached --name-only | wc -l | tr -d ' ')
if [ "$PENDING" -gt 0 ]; then
  echo -n "Commit message (or press Enter to push existing commits only): "
  read -r msg
  [ -n "$msg" ] && git commit -m "$msg"
fi

git push origin develop
echo ""
echo "Done. Pushed to develop → open a PR from develop → main to trigger CI."
echo "Press any key to close."
read -n 1
