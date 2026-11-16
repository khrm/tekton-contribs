#!/bin/bash
# Fetches review stats (review events, unique PRs reviewed, review comments)
# for all PRs in one or more GitHub orgs updated within a given time range.
#
# Usage:
#   ./review.sh    # tektoncd + shipwright-io + openshift-pipelines + redhat-openshift-builds, last 7 days
#   ./review.sh --org tektoncd --days 14
#   ./review.sh --org tektoncd --org shipwright-io
#   ./review.sh --org tektoncd,shipwright-io,another-org
#   REVIEW_ORGS="org1,org2" ./review.sh      # override default orgs
#   ./review.sh --org tektoncd --days 30 --format csv
#   ./review.sh --org tektoncd --format md
#   ./review.sh --exclude-author my-bot      # replace default excluded authors
#   REVIEW_EXCLUDE_AUTHORS="bot1,app/dependabot" ./review.sh  # or via env ("" to disable)
#
# Requires: gh (GitHub CLI), jq

set -euo pipefail

DAYS=7
FORMAT="tsv"
ORGS=()
EXCLUDE=()

DEFAULT_ORGS="tektoncd,shipwright-io,openshift-pipelines,redhat-openshift-builds"
DEFAULT_EXCLUDE_AUTHORS="openshift-pipelines-bot,app/red-hat-konflux-kflux-prd-rh02,app/github-actions,app/pipelines-as-code-ci-app"
GITHUB_NAME='[a-zA-Z0-9._-]+'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --org|--days|--format|--exclude-author)
            if [[ $# -lt 2 ]] || [[ "$2" == --* ]]; then
                >&2 echo "Error: $1 requires a value"
                exit 1
            fi
            case "$1" in
                --org) ORGS+=("$2") ;;
                --exclude-author) EXCLUDE+=("$2") ;;
                --days) DAYS="$2" ;;
                --format) FORMAT="$2" ;;
            esac
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

# Allow comma-separated values (e.g. a,b) and drop duplicates
normalize_list() {
    local -n _dst=$1
    shift
    local -A _seen=()
    local _tmp=() entry p parts
    for entry in "$@"; do
        IFS=',' read -ra parts <<< "$entry"
        for p in "${parts[@]}"; do
            [[ -z "$p" ]] && continue
            [[ -n "${_seen[$p]:-}" ]] && continue
            _seen[$p]=1
            _tmp+=("$p")
        done
    done
    _dst=("${_tmp[@]}")
}

if [[ ${#ORGS[@]} -eq 0 ]]; then
    ORGS=("${REVIEW_ORGS:-$DEFAULT_ORGS}")
fi
normalize_list ORGS "${ORGS[@]}"

for org in "${ORGS[@]}"; do
    if [[ ! "$org" =~ ^${GITHUB_NAME}$ ]]; then
        >&2 echo "Error: Invalid org name '$org'. Only alphanumeric, hyphen, underscore, and dot allowed."
        exit 1
    fi
done

if [[ ${#EXCLUDE[@]} -eq 0 ]]; then
    EXCLUDE=("${REVIEW_EXCLUDE_AUTHORS-$DEFAULT_EXCLUDE_AUTHORS}")
fi
normalize_list EXCLUDE "${EXCLUDE[@]}"

# Build the search-level exclusion terms and the login list used to filter
# review/comment authors in jq (strip the app/ prefix for login matching)
EXCLUDE_TERMS=()
for entry in "${EXCLUDE[@]}"; do
    if [[ ! "$entry" =~ ^${GITHUB_NAME}(/${GITHUB_NAME})?$ ]]; then
        >&2 echo "Error: Invalid author exclusion '$entry'. Use 'login' or 'app/login'."
        exit 1
    fi
    EXCLUDE_TERMS+=("-author:$entry")
done
# Keep the leading space in the query so __EXCLUDE__ can sit directly after
# __SINCE__ and produce an identical query whether or not there are exclusions.
EXCLUDE_QUERY=""
if [[ ${#EXCLUDE_TERMS[@]} -gt 0 ]]; then
    EXCLUDE_QUERY=" ${EXCLUDE_TERMS[*]}"
fi
EXCLUDED_JSON=$(printf '%s\n' "${EXCLUDE[@]}" | sed 's|^app/||' | jq -Rsc 'split("\n") | map(select(length > 0))')

# jq prelude: true when the login in `.` is not excluded
# $excluded and $l are jq variables, not shell (hence disable=SC2016)
# shellcheck disable=SC2016
JQ_EXCLUDED='def not_excluded: . as $l | ($excluded | index($l) | not);'

# jq fragment for REVIEW_JQ: keep only review authors that are not excluded
AUTHOR_FILTER='select(.author != null and .author.login != null) |
      select(.author.login | not_excluded)'

SINCE=$(date -d "$DAYS days ago" +%Y-%m-%d 2>/dev/null || date -v-"${DAYS}d" +%Y-%m-%d)

>&2 echo "Orgs: ${ORGS[*]}"
if [[ ${#EXCLUDE[@]} -gt 0 ]]; then
    >&2 echo "Excluded authors: ${EXCLUDE[*]}"
fi
>&2 echo "Fetching PRs updated since $SINCE ..."

TMPDIR=$(mktemp -d)
REVIEWS_FILE="$TMPDIR/reviews.tsv"
COMMENTS_FILE="$TMPDIR/comments.tsv"
REPOS_FILE="$TMPDIR/repos.txt"
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

        # Substitute placeholders without sed so app/ logins (which contain
        # slashes) cannot break the replacement.
        local query="$query_template"
        query=${query//__AFTER__/$after}
        query=${query//__SINCE__/$SINCE}
        query=${query//__EXCLUDE__/$EXCLUDE_QUERY}

        result=$(gh api graphql -f query="$query" 2>&1 || true)

        if ! echo "$result" | jq -e '.data.search' >/dev/null 2>&1; then
            err=$(echo "$result" | jq -r '.errors[0].message // empty' 2>/dev/null || true)
            if [ -n "$err" ]; then
                >&2 echo "GraphQL error on page $page: $err"
            else
                >&2 echo "API/non-JSON error on page $page: $(echo "$result" | head -c 500 | tr '\n' ' ')"
            fi
            break
        fi

        # One jq pass per page: P = pagination, R = repo name, V = review row
        local page_out
        page_out=$(echo "$result" | jq -r --arg since "$SINCE" --argjson excluded "$EXCLUDED_JSON" "$JQ_EXCLUDED"'
            "P\t\(.data.search.pageInfo.hasNextPage)\t\(.data.search.pageInfo.endCursor // "")",
            (.data.search.nodes[]?.repository.nameWithOwner // empty | "R\t" + .),
            (('"$jq_filter"') | "V\t" + .)')

        has_next=""
        while IFS=$'\t' read -r tag f1 f2; do
            case "$tag" in
                P) has_next="$f1"; cursor="$f2" ;;
                R) echo "$f1" >> "$REPOS_FILE" ;;
                V) printf '%s\t%s\n' "$f1" "$f2" ;;
            esac
        done <<< "$page_out"

        >&2 echo "  Page $page done"
        page=$((page + 1))

        if [ "$has_next" != "true" ]; then
            break
        fi
    done
}

# Read repo names (one per line) on stdin; emit "login<TAB>1" per review comment.
fetch_rest_comments() {
    local repo comments_json
    while read -r repo; do
        [[ -n "$repo" ]] || continue
        comments_json=$(gh api --paginate \
            "repos/$repo/pulls/comments?since=${SINCE}T00:00:00Z&per_page=100" 2>/dev/null || true)
        if ! echo "$comments_json" | jq -r -s --arg since "$SINCE" --argjson excluded "$EXCLUDED_JSON" "$JQ_EXCLUDED"'
            if all(.[]; type == "array") then
              .[][] | select(.user != null and .user.login != null) |
              select(.user.login | not_excluded) |
              select(.created_at != null and .created_at >= $since) |
              "\(.user.login)\t1"
            else
              error("unexpected response shape")
            end'; then
            >&2 echo "  Failed to fetch review comments for $repo"
        fi
    done
}

for org in "${ORGS[@]}"; do
    >&2 echo "Fetching review events for $org..."
    REVIEW_QUERY='{
      search(query: "org:'"$org"' is:pr updated:>__SINCE____EXCLUDE__", type: ISSUE, first: 100, after: __AFTER__) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            number
            repository { nameWithOwner }
            reviews(last: 100) {
              totalCount
              nodes { author { login } submittedAt }
            }
          }
        }
      }
    }'

    # $repo/$pr/$since are jq variables and $AUTHOR_FILTER is deliberately
    # expanded by the shell, so SC2016 doesn't apply here
    # shellcheck disable=SC2016
    REVIEW_JQ='.data.search.nodes[] |
      .repository.nameWithOwner as $repo |
      .number as $pr |
      (.reviews | select(.totalCount > 100) | "truncated reviews for \($repo)#\($pr): \(.totalCount)" | debug | empty),
      (.reviews.nodes[] |
      '"$AUTHOR_FILTER"' |
      select(.submittedAt != null and .submittedAt >= $since) |
      "\(.author.login)\t\($repo)#\($pr)")'

    fetch_pages "$REVIEW_QUERY" "$REVIEW_JQ" >> "$REVIEWS_FILE"
done

# GraphQL has no server-side date filter for review comments, so fetch them
# per repository from the REST API, which supports ?since= instead of fetching
# every review's full comment history.
if [[ -s "$REPOS_FILE" ]]; then
    mapfile -t REPOS < <(sort -u "$REPOS_FILE")
    >&2 echo "Fetching review comments for ${#REPOS[@]} repos..."
    printf '%s\n' "${REPOS[@]}" | fetch_rest_comments >> "$COMMENTS_FILE"
fi

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
