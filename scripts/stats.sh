#!/bin/bash
# Download counts for every release, plus GitHub's repo traffic for the last 14 days.
#
#   scripts/stats.sh
#   GH_TOKEN="$(gh auth token --user <owner>)" scripts/stats.sh   # traffic needs push access
#
# Website visits aren't here: GitHub Pages has no analytics. See the GoatCounter dashboard
# once GOATCOUNTER_CODE is set in docs/app.js.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${REPO:-$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

bold "Downloads ($REPO)"
gh api "repos/$REPO/releases" --paginate \
  --jq '.[] | .tag_name as $t | .published_at[0:10] as $d | .assets[] | "  \($t)  \(.name)  \(.download_count)   (published \($d))"'
total="$(gh api "repos/$REPO/releases" --paginate --jq '[.[].assets[].download_count] | add // 0')"
echo "  Total: $total"

echo
bold "Repo stars and forks"
gh api "repos/$REPO" --jq '"  \(.stargazers_count) stars, \(.forks_count) forks, \(.subscribers_count) watching"'

echo
bold "Repo page views, last 14 days"
if gh api "repos/$REPO/traffic/views" >/dev/null 2>&1; then
  gh api "repos/$REPO/traffic/views" \
    --jq '"  \(.count) views, \(.uniques) unique visitors", (.views[-7:][] | "    \(.timestamp[0:10])  \(.count) views, \(.uniques) unique")'
  echo
  bold "Where repo visitors came from"
  gh api "repos/$REPO/traffic/popular/referrers" \
    --jq 'if length == 0 then "  (none yet)" else .[] | "  \(.referrer): \(.count) views, \(.uniques) unique" end'
else
  echo "  Needs a token with push access to $REPO (set GH_TOKEN)."
fi
