#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

echo "::group::Cleanup Prior Reviews"

OWNER="${GITHUB_REPOSITORY%%/*}"
REPO="${GITHUB_REPOSITORY##*/}"

reviews=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --paginate 2>/dev/null || echo "[]")

BOT_LOGIN="github-actions[bot]"

echo "$reviews" | jq -r --arg bot "$BOT_LOGIN" \
  '.[] | select(.user.login == $bot and .state == "CHANGES_REQUESTED") | .id' | \
while IFS= read -r review_id; do
  [[ -z "$review_id" ]] && continue
  echo "Dismissing REQUEST_CHANGES review $review_id"
  gh api -X PUT "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$review_id/dismissals" \
    -f message="Superseded by new review run" \
    --silent 2>/dev/null || echo "Warning: failed to dismiss review $review_id"
done

echo "$reviews" | jq -r --arg bot "$BOT_LOGIN" \
  '.[] | select(.user.login == $bot and .state == "PENDING") | .id' | \
while IFS= read -r review_id; do
  [[ -z "$review_id" ]] && continue
  echo "Deleting PENDING review $review_id"
  gh api -X DELETE "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$review_id" \
    --silent 2>/dev/null || echo "Warning: failed to delete review $review_id"
done

comments=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments" --paginate 2>/dev/null || echo "[]")

comment_node_ids=$(echo "$comments" | jq -r --arg marker "$REVIEW_MARKER" \
  '.[] | select(.body | contains($marker)) | .node_id' 2>/dev/null || true)

while IFS= read -r node_id; do
  [[ -z "$node_id" ]] && continue
  echo "Minimizing comment $node_id"
  gh api graphql -f query="
    mutation {
      minimizeComment(input: {subjectId: \"$node_id\", classifier: OUTDATED}) {
        minimizedComment {
          isMinimized
        }
      }
    }
  " --silent 2>/dev/null || echo "Warning: failed to minimize comment $node_id"
done <<< "$comment_node_ids"

echo "Cleanup complete"
echo "::endgroup::"
