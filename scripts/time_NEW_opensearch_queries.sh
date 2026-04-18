#!/usr/bin/env bash
# Test the NEW (optimized) OpenSearch query shapes for all three indexes.
# Run this on the EC2 to confirm speed improvement BEFORE deploying code changes.
#
# Usage:  ./time_new_opensearch_queries.sh [search_term]
# Example: ./time_new_opensearch_queries.sh medicare
#
# Compare results against the OLD script: ./time_all_opensearch_queries.sh
#
# Key differences from the old queries:
#   comments / comments_extracted_text:
#     - Match clause moved to top-level "query" (uses inverted index = fast)
#     - Inner "by_comment" terms agg replaced with "cardinality" agg (fixed memory)
#   documents_text: unchanged (was already fast)

set -euo pipefail

ENDPOINT="https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com"
TERM="${1:-medicare}"

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

Q="$(json_escape "$TERM")"

echo "============================================================"
echo " Testing NEW optimized OpenSearch query shapes"
echo " Search term: \"${TERM}\""
echo " Endpoint:    ${ENDPOINT}"
echo "============================================================"
echo ""

# ------------------------------------------------------------
# documents_text — unchanged, already fast, here for baseline
# ------------------------------------------------------------
echo "========== documents_text (unchanged baseline) =========="
time awscurl --service aoss --region us-east-1 \
  -X POST "${ENDPOINT}/documents_text/_search" \
  -H "Content-Type: application/json" \
  -d "{
  \"size\": 0,
  \"aggs\": {
    \"by_docket\": {
      \"terms\": {
        \"field\": \"docketId.keyword\",
        \"size\": 50000
      },
      \"aggs\": {
        \"matching_docs\": {
          \"filter\": {
            \"bool\": {
              \"should\": [
                {
                  \"multi_match\": {
                    \"query\": \"${Q}\",
                    \"fields\": [\"title\", \"documentText\"]
                  }
                }
              ],
              \"minimum_should_match\": 1
            }
          }
        }
      }
    }
  }
}"
echo ""

# ------------------------------------------------------------
# comments — NEW: top-level query filter + cardinality agg
# ------------------------------------------------------------
echo "========== comments (NEW — query filter + cardinality) =========="
echo "  OLD approach: nested by_comment terms agg (crashed)"
echo "  NEW approach: top-level query pre-filter, cardinality for unique count"
echo ""
time awscurl --service aoss --region us-east-1 \
  -X POST "${ENDPOINT}/comments/_search" \
  -H "Content-Type: application/json" \
  -d "{
  \"size\": 0,
  \"query\": {
    \"bool\": {
      \"should\": [
        {
          \"match\": {
            \"commentText\": \"${Q}\"
          }
        }
      ],
      \"minimum_should_match\": 1
    }
  },
  \"aggs\": {
    \"by_docket\": {
      \"terms\": {
        \"field\": \"docketId.keyword\",
        \"size\": 50000
      },
      \"aggs\": {
        \"unique_comment_count\": {
          \"cardinality\": {
            \"field\": \"commentId.keyword\",
            \"precision_threshold\": 1000
          }
        }
      }
    }
  }
}"
echo ""

# ------------------------------------------------------------
# comments_extracted_text — NEW: same pattern on extractedText
# ------------------------------------------------------------
echo "========== comments_extracted_text (NEW — query filter + cardinality) =========="
echo "  OLD approach: nested by_comment terms agg (crashed)"
echo "  NEW approach: top-level query pre-filter, cardinality for unique count"
echo ""
time awscurl --service aoss --region us-east-1 \
  -X POST "${ENDPOINT}/comments_extracted_text/_search" \
  -H "Content-Type: application/json" \
  -d "{
  \"size\": 0,
  \"query\": {
    \"bool\": {
      \"should\": [
        {
          \"match\": {
            \"extractedText\": \"${Q}\"
          }
        }
      ],
      \"minimum_should_match\": 1
    }
  },
  \"aggs\": {
    \"by_docket\": {
      \"terms\": {
        \"field\": \"docketId.keyword\",
        \"size\": 50000
      },
      \"aggs\": {
        \"unique_comment_count\": {
          \"cardinality\": {
            \"field\": \"commentId.keyword\",
            \"precision_threshold\": 1000
          }
        }
      }
    }
  }
}"
echo ""

# ------------------------------------------------------------
# Optional: print a note about the one-time index setting
# ------------------------------------------------------------
echo "============================================================"
echo " REMINDER: Apply this one-time cluster setting for both"
echo " comments and comments_extracted_text indexes to pre-warm"
echo " the docketId.keyword ordinals (speeds up repeated searches):"
echo ""
echo "   curl -sSk -u 'admin:YOUR_PASSWORD' \\"
echo "     -X PUT 'https://localhost:9200/comments/_mapping' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"properties\":{\"docketId\":{\"type\":\"text\",\"fields\":{\"keyword\":{\"type\":\"keyword\",\"ignore_above\":256,\"eager_global_ordinals\":true}}}}}'"
echo ""
echo "   (Repeat with comments_extracted_text in the URL)"
echo "============================================================"
