#!/bin/bash
# Fetches review stats (review events, unique PRs reviewed, review comments)
# for all PRs in one or more GitHub orgs updated within a given time range.
#
# Usage:
#   ./github-review-stats.sh                              # tektoncd, last 7 days
#   ./github-review-stats.sh --org tektoncd --days 14
#   ./github-review-stats.sh --org tektoncd --org openshift-pipelines
#   ./github-review-stats.sh --org tektoncd --days 30 --format csv
#   ./github-review-stats.sh --org tektoncd --format md
#
# Requires: gh (GitHub CLI), jq

set -euo pipefail

DAYS=7
FORMAT="tsv"
ORGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --org|--days|--format)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                >&2 echo "Error: $1 requires a value"
                exit 1
            fi
            ;;&
        --org)
            ORGS+=("$2")
            shift 2
            ;;
        --days)
            DAYS="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --help|-h)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0
            ;;
        *)
            >&2 echo "Unknown option: $1"
            >&2 echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

if [[ ${#ORGS[@]} -eq 0 ]]; then
    ORGS=("tektoncd")
fi

for org in "${ORGS[@]}"; do
    if [[ ! "$org" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        >&2 echo "Error: Invalid org name '$org'. Only alphanumeric, hyphen, underscore, and dot allowed."
        exit 1
    fi
done

SINCE=$(date -d "$DAYS days ago" +%Y-%m-%d 2>/dev/null || date -v-"${DAYS}d" +%Y-%m-%d)

>&2 echo "Orgs: ${ORGS[*]}"
>&2 echo "Fetching PRs updated since $SINCE ..."

TMPDIR=$(mktemp -d)
REVIEWS_FILE="$TMPDIR/reviews.tsv"
COMMENTS_FILE="$TMPDIR/comments.tsv"
trap 'rm -rf "$TMPDIR"' EXIT

fetch_pages() {
    local query_template="$1"
    local jq_filter="$2"
    local cursor=""
    local page=1

    while true; do
        if [ -z "$cursor" ]; then
            after="null"
        else
            after="\"$cursor\""
        fi

        local query
        query=$(echo "$query_template" | sed "s/__AFTER__/$after/g" | sed "s/__SINCE__/$SINCE/g")

        result=$(gh api graphql -f query="$query" 2>&1)

        err=$(echo "$result" | jq -r '.errors[0].message // empty' 2>/dev/null)
        if [ -n "$err" ]; then
            >&2 echo "GraphQL error on page $page: $err"
            break
        fi

        echo "$result" | jq -r "$jq_filter"

        has_next=$(echo "$result" | jq -r '.data.search.pageInfo.hasNextPage')
        cursor=$(echo "$result" | jq -r '.data.search.pageInfo.endCursor')

        >&2 echo "  Page $page done"
        page=$((page + 1))

        if [ "$has_next" != "true" ]; then
            break
        fi
    done
}

for org in "${ORGS[@]}"; do
    >&2 echo "Fetching review events for $org..."
    REVIEW_QUERY='{
      search(query: "org:'"$org"' is:pr updated:>__SINCE__", type: ISSUE, first: 100, after: __AFTER__) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            number
            repository { nameWithOwner }
            reviews(first: 100) {
              nodes { author { login } }
            }
          }
        }
      }
    }'

    REVIEW_JQ='.data.search.nodes[] |
      .repository.nameWithOwner as $repo |
      .number as $pr |
      .reviews.nodes[] |
      "\(.author.login)\t\($repo)#\($pr)"'

    fetch_pages "$REVIEW_QUERY" "$REVIEW_JQ" >> "$REVIEWS_FILE"

    >&2 echo "Fetching review comments for $org..."
    COMMENTS_QUERY='{
      search(query: "org:'"$org"' is:pr updated:>__SINCE__", type: ISSUE, first: 50, after: __AFTER__) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            number
            repository { nameWithOwner }
            reviews(first: 50) {
              nodes {
                author { login }
                comments(first: 50) {
                  totalCount
                }
              }
            }
          }
        }
      }
    }'

    COMMENTS_JQ='.data.search.nodes[] |
      .reviews.nodes[] |
      "\(.author.login)\t\(.comments.totalCount)"'

    fetch_pages "$COMMENTS_QUERY" "$COMMENTS_JQ" >> "$COMMENTS_FILE"
done

# Compute stats
>&2 echo "Computing stats..."

review_events=$(cut -f1 "$REVIEWS_FILE" | sort | uniq -c | sort -rn | awk '{print $2"\t"$1}')
unique_prs=$(sort -u "$REVIEWS_FILE" | cut -f1 | sort | uniq -c | sort -rn | awk '{print $2"\t"$1}')
review_comments=$(awk -F'\t' '{sum[$1]+=$2} END {for(u in sum) print u"\t"sum[u]}' "$COMMENTS_FILE" | sort -t$'\t' -k2 -rn)

# Merge into a single table
declare -A EVENTS UNIQUE COMMENTS_MAP

while IFS=$'\t' read -r user count; do
    EVENTS["$user"]=$count
done <<< "$review_events"

while IFS=$'\t' read -r user count; do
    UNIQUE["$user"]=$count
done <<< "$unique_prs"

while IFS=$'\t' read -r user count; do
    COMMENTS_MAP["$user"]=$count
done <<< "$review_comments"

# Collect all users
ALL_USERS=()
for user in "${!EVENTS[@]}"; do
    ALL_USERS+=("$user")
done
for user in "${!COMMENTS_MAP[@]}"; do
    if [ -z "${EVENTS[$user]+x}" ]; then
        ALL_USERS+=("$user")
    fi
done

# Sort by review events descending
sorted_users=$(for user in "${ALL_USERS[@]}"; do
    echo "${EVENTS[$user]:-0} $user"
done | sort -rn | awk '{print $2}')

# Output
case "$FORMAT" in
    csv)
        echo "Reviewer,Review Events,Unique PRs,Review Comments"
        while read -r user; do
            echo "$user,${EVENTS[$user]:-0},${UNIQUE[$user]:-0},${COMMENTS_MAP[$user]:-0}"
        done <<< "$sorted_users"
        ;;
    md)
        echo "| Reviewer | Review Events | Unique PRs | Review Comments |"
        echo "|---|---|---|---|"
        while read -r user; do
            echo "| $user | ${EVENTS[$user]:-0} | ${UNIQUE[$user]:-0} | ${COMMENTS_MAP[$user]:-0} |"
        done <<< "$sorted_users"
        ;;
    *)
        echo -e "Reviewer\tReview Events\tUnique PRs\tReview Comments"
        while read -r user; do
            echo -e "$user\t${EVENTS[$user]:-0}\t${UNIQUE[$user]:-0}\t${COMMENTS_MAP[$user]:-0}"
        done <<< "$sorted_users"
        ;;
esac

>&2 echo "Done. Period: $SINCE to today. Orgs: ${ORGS[*]}"
