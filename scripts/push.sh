#!/bin/bash
# Push current branch to GitHub using a stored PAT.
# Reads token from .push-token at the repo root (gitignored — never commit it).
# Usage: bash scripts/push.sh [branch]   (defaults to current branch)
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

TOKEN_FILE="$REPO/.push-token"
if [ ! -f "$TOKEN_FILE" ]; then
  echo "ERROR: $TOKEN_FILE not found."
  echo "Create it with your GitHub PAT (classic, repo scope):"
  echo "  echo 'ghp_your_token_here' > .push-token"
  exit 1
fi

TOKEN="$(cat "$TOKEN_FILE" | tr -d '[:space:]')"
BRANCH="${1:-$(git --no-optional-locks branch --show-current)}"
REMOTE_URL="$(git --no-optional-locks remote get-url origin)"

# Inject token into HTTPS URL: https://github.com/... → https://<token>@github.com/...
AUTH_URL="${REMOTE_URL/https:\/\//https://$TOKEN@}"

echo "Pushing $BRANCH → origin"
git --no-optional-locks push "$AUTH_URL" "$BRANCH"
echo "Pushed: $BRANCH"
