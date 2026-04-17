#!/usr/bin/env bash
# Time the app's text-match queries for all three OpenSearch indexes.
# Run from the directory that contains both scripts (same dir in prod).
# Usage: time_all_opensearch_text_matches.sh [search_term]
# Example: time_all_opensearch_text_matches.sh medicare

set -euo pipefail

TERM="${1:-medicare}"

for INDEX in documents_text comments comments_extracted_text; do
  echo "========== ${INDEX} =========="
  time ./opensearch_text_match.sh "$INDEX" "$TERM"
  echo
done