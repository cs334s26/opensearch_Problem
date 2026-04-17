#!/usr/bin/env bash
# Quick OpenSearch text-match timing test (awscurl + IAM on the instance).
# Usage: opensearch_text_match.sh <index> <search_term>

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <index> <search_term>" >&2
  exit 1
fi

# JSON string contents for $2 (backslash and double-quote)
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

ENDPOINT="https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com"
Q="$(json_escape "$2")"

case "$1" in
  documents_text)
    BODY=$(cat <<EOF
{
  "size": 0,
  "aggs": {
    "by_docket": {
      "terms": {
        "field": "docketId.keyword",
        "size": 50000
      },
      "aggs": {
        "matching_docs": {
          "filter": {
            "bool": {
              "should": [
                {
                  "multi_match": {
                    "query": "${Q}",
                    "fields": ["title", "documentText"]
                  }
                }
              ],
              "minimum_should_match": 1
            }
          }
        }
      }
    }
  }
}
EOF
    )
    ;;
  comments)
    BODY=$(cat <<EOF
{
  "size": 0,
  "aggs": {
    "by_docket": {
      "terms": {
        "field": "docketId.keyword",
        "size": 50000
      },
      "aggs": {
        "matching_comments": {
          "filter": {
            "bool": {
              "should": [
                {
                  "match": {
                    "commentText": "${Q}"
                  }
                }
              ],
              "minimum_should_match": 1
            }
          },
          "aggs": {
            "by_comment": {
              "terms": {
                "field": "commentId.keyword",
                "size": 65535
              }
            }
          }
        }
      }
    }
  }
}
EOF
    )
    ;;
  comments_extracted_text)
    BODY=$(cat <<EOF
{
  "size": 0,
  "aggs": {
    "by_docket": {
      "terms": {
        "field": "docketId.keyword",
        "size": 50000
      },
      "aggs": {
        "matching_extracted": {
          "filter": {
            "bool": {
              "should": [
                {
                  "match": {
                    "extractedText": "${Q}"
                  }
                }
              ],
              "minimum_should_match": 1
            }
          },
          "aggs": {
            "by_comment": {
              "terms": {
                "field": "commentId.keyword",
                "size": 65535
              }
            }
          }
        }
      }
    }
  }
}
EOF
    )
    ;;
  *)
    echo "unknown index: $1 (use documents_text, comments, or comments_extracted_text)" >&2
    exit 1
    ;;
esac

exec awscurl --service aoss --region us-east-1 \
  -X POST "${ENDPOINT}/$1/_search" \
  -H "Content-Type: application/json" \
  -d "$BODY"