#!/usr/bin/env bash
# comments: full-text query (match on commentText) + per-docket document counts.
#
# Usage: aggregated_comments_search.sh <term> [term ...]
#   Quote a multi-word phrase: aggregated_comments_search.sh medicare "part d"
#
# Behavior:
#   - Each argument is one search phrase; phrases are OR'd (bool.should, min_should_match 1).
#   - match: query on commentText field.
#   - Aggregates by docketId.keyword, size capped at 50000 (< default search.max_buckets 65535).
#   - Bucket order: by match count descending (most matching comments first).
#
# Note: With "size": 0, no hits are returned; boosts affect _score only, not
#   which documents match or per-docket doc_count. They matter if you later return hits.
#
# Requires: awscurl, AWS credentials (e.g. EC2 instance role).
#

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <term> [term ...]" >&2
  exit 1
fi

ENDPOINT="https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com"
INDEX="comments"
MAX_DOCKET_BUCKETS=50000

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Build JSON array of match clauses on commentText (one per argument).
build_should_clauses() {
  local sep="" term q
  printf '['
  for term in "$@"; do
    q=$(json_escape "$term")
    printf '%s' "$sep"
    printf '%s' '{"match":{"commentText":{"query":"'"$q"'","operator":"or"}}}'
    sep=","
  done
  printf ']'
}

SHOULD_JSON="$(build_should_clauses "$@")"

BODY=$(cat <<EOF
{
  "size": 0,
  "track_total_hits": true,
  "query": {
    "bool": {
      "should": ${SHOULD_JSON},
      "minimum_should_match": 1
    }
  },
  "aggs": {
    "by_docket": {
      "terms": {
        "field": "docketId.keyword",
        "size": ${MAX_DOCKET_BUCKETS},
        "shard_size": 55000,
        "order": { "_count": "desc" }
      }
    }
  }
}
EOF
)

if [ -z "$BODY" ]; then
  echo "$0: internal error: empty request body" >&2
  exit 1
fi

START=$(date +%s%3N)

awscurl --service aoss --region us-east-1 \
  -X POST "${ENDPOINT}/${INDEX}/_search" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d "$BODY"

END=$(date +%s%3N)
echo ""
echo "elapsed: $((END - START)) ms"
