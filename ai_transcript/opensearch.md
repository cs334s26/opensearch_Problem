# Document index querying code
_Exported on 4/17/2026 at 21:38:22 EDT from Cursor (3.1.15)_

---

**User**

This project contains a system that runs a query against an opensearch instance.  I know there are queries for document text and comment text.  where is the code for queriring against the document index?

---

**Cursor**


Searching the codebase for OpenSearch queries against the document index.




Locating `_run_text_match_queries` and document-specific query construction.




Here’s where document full-text search against OpenSearch is implemented.

## Primary location: `DBLayer` in `src/mirrsearch/db.py`

**Entry point:** `text_match_terms()` calls `_run_text_match_queries()`:

```386:401:src/mirrsearch/db.py
    def text_match_terms(
            self, terms: List[str], opensearch_client=None) -> List[Dict[str, Any]]:
        """
        Search OpenSearch for dockets containing the given terms.

        Searches:
        - documents_text index: title and documentText fields
        - comments index: commentText field
        - comments_extracted_text index: extractedText field

        Returns list of {docket_id, document_match_count, comment_match_count}.
        """
        if opensearch_client is None:
            opensearch_client = get_opensearch_connection()
        try:
            return self._run_text_match_queries(opensearch_client, terms)
```

**Actual document query:** In `_run_text_match_queries()`, the document leg is a `search()` on the **`documents_text`** index with `multi_match` on **`title`** and **`documentText`**:

```493:518:src/mirrsearch/db.py
        docket_counts: Dict = {}
        doc_resp = safe_search(
            "documents_text",
            self._build_docket_agg_query(
                "matching_docs",
                [{"multi_match": {"query": t, "fields": ["title", "documentText"]}}
                 for t in terms],
            ),
        )
        comment_resp = safe_search(
            "comments",
            self._build_docket_agg_query_unique_comments(
                "matching_comments",
                [{"match": {"commentText": t}} for t in terms],
            ),
        )
        ...
        self._accumulate_counts(
            docket_counts, buckets(doc_resp), "matching_docs", "document_match_count"
        )
```

**Query shape:** The aggregation wrapper (per-docket buckets + inner filter) is built by `_build_docket_agg_query()`:

```285:308:src/mirrsearch/db.py
    @staticmethod
    def _build_docket_agg_query(agg_name: str, match_clauses: List[Dict]) -> Dict:
        """Build a docket-bucketed aggregation query with an inner filter."""
        return {
            "size": 0,
            "aggs": {
                "by_docket": {
                    "terms": {
                        "field": "docketId.keyword",
                        "size": _opensearch_match_docket_bucket_size(),
                    },
                    "aggs": {
                        agg_name: {
                            "filter": {
                                "bool": {
                                    "should": match_clauses,
                                    "minimum_should_match": 1
                                }
                            }
                        }
                    }
                }
            }
        }
```

**Call chain from the API:** `InternalLogic.search()` uses `self.db_layer.text_match_terms(...)` to merge OpenSearch hits with SQL title search (`src/mirrsearch/internal_logic.py`).

---

**Index name note:** Runtime search targets **`documents_text`**. Elsewhere (e.g. `db/ingest.py`) you may see a **`documents`** index used for ingestion; `docs/OpensearchInfo.md` documents `documents_text`. If your cluster only has `documents`, names would need to align (alias or code change)—worth confirming in your deployment.

---

**User**

Users can provide a search term to query against the document text.  I want to test the speed of this query by manually running a curl command on our EC2 instance against production database that has about 400K records.  Give me a curl command to do this with the serch term "medicare."

---

**Cursor**


Checking how OpenSearch connection and requests are configured so the curl matches the app's query and URL pattern.




Here’s a **curl** that runs the **same document-text query** the app uses: index `documents_text`, `multi_match` on `title` and `documentText`, per-docket aggregation with inner filter `matching_docs`, default bucket size **50000** (same default as `OPENSEARCH_MATCH_DOCKET_BUCKET_SIZE` in code).

### HTTPS + basic auth (typical on EC2 when `.env` has user/password)

Run **on the instance** (or anywhere that can reach the cluster). Fill in host/port/credentials from your server `.env`, or export them first.

```bash
curl -sS -k \
  -u "${OPENSEARCH_USER}:${OPENSEARCH_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -X POST "https://${OPENSEARCH_HOST}:${OPENSEARCH_PORT:-9200}/documents_text/_search" \
  -d '{
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
                      "query": "medicare",
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
  }' \
  -w '\nHTTP %{http_code}  total_time_sec %{time_total}\n'
```

- **`-k`**: skip TLS verify (matches the app when `OPENSEARCH_VERIFY_CERTS` is not true / self-signed). Omit `-k` if you use a proper CA and want strict verification.
- **Timing**: `time_total` is end-to-end request time; good enough for a quick benchmark. For wall-clock: `time curl ...` (drop `-s` if you want to see bytes returned).

### Plain HTTP (e.g. local OpenSearch on the box)

```bash
curl -sS -H 'Content-Type: application/json' \
  -X POST "http://localhost:9200/documents_text/_search" \
  -d '{ ... same JSON ... }' \
  -w '\nHTTP %{http_code}  total_time_sec %{time_total}\n'
```

### Things to align with production

1. **Bucket size** — If production sets `OPENSEARCH_MATCH_DOCKET_BUCKET_SIZE`, use that number instead of `50000` in the `terms.size` field so the query matches the app.
2. **Index name** — Code uses `documents_text`. If your cluster only has `documents`, point the URL at that index (or an alias) instead.
3. **Amazon OpenSearch Serverless (`aoss.amazonaws.com`)** — The app uses **AWS SigV4**, not basic auth; plain `curl -u` won’t work. Use something that signs requests (e.g. `awscurl`) or test from the app path.

This exercises **OpenSearch only** (~400K document records there), not Postgres.

---

**User**

The authorization is handled via IAM, which why I have to run this test on the EC2 instance.  There is no username/password access.  Does this change how I run the query using curl?

---

**Cursor**

Yes — with IAM auth, plain `curl` is not enough by itself because the request must be **SigV4-signed**.

Use one of these on the EC2 instance (where the instance role provides credentials):

- `awscurl` (simplest)
- `curl` + an AWS signing helper
- `aws opensearchserverless`/SDK (if using Serverless; for regular OpenSearch domains, signed HTTP is still typical)

For your case, `awscurl` is easiest.

```bash
awscurl --service aoss --region us-east-1 \
  -X POST "https://YOUR_COLLECTION_ENDPOINT/documents_text/_search" \
  -H 'Content-Type: application/json' \
  -d '{
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
                      "query": "medicare",
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
  }'
```

If this is **managed OpenSearch domain** (not Serverless), switch `--service aoss` to `--service es`.

Quick timing:

```bash
time awscurl --service aoss --region us-east-1 -X POST "https://YOUR_ENDPOINT/documents_text/_search" -H 'Content-Type: application/json' -d '...'
```

If you want, I can give you a copy-paste command that auto-detects whether to use `es` vs `aoss` from your endpoint string.

---

**User**

We have been able to curl without doing any of that stuff.

---

**Cursor**

That makes sense — if you can already `curl` directly, your endpoint is likely allowing access by **network policy/IP/VPC** (or you’re hitting a local proxy), so SigV4 isn’t required in that path.

In that case, keep it simple and run the raw OpenSearch query directly:

```bash
curl -sS -X POST "http://YOUR_OPENSEARCH_HOST:9200/documents_text/_search" \
  -H "Content-Type: application/json" \
  -d '{
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
                      "query": "medicare",
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
  }' \
  -w '\nHTTP %{http_code}  total_time_sec %{time_total}\n'
```

If you want to sanity-check you’re querying the right backend first:

```bash
curl -sS "http://YOUR_OPENSEARCH_HOST:9200/"
```

If that returns cluster info JSON, you’re good to use plain `curl` for this benchmark.

---

**User**

what is the -w ... doing?

---

**Cursor**

 In `curl`, **`-w` / `--write-out`** prints extra information **after** the response body, using placeholders that `curl` fills in.

So this part:

```bash
-w '\nHTTP %{http_code}  total_time_sec %{time_total}\n'
```

means:

- **`%{http_code}`** — HTTP status (e.g. `200`, `401`).
- **`%{time_total}`** — seconds from start of the request until the transfer finished (good for a quick latency check).

The leading `\n` puts that line on a **new line** after the JSON body so it’s easier to read. Without `-w`, you’d only see the response body.

**Note:** If you also use `-o /dev/null` to discard the body, `-w` still runs and you mainly see the metrics — useful when you only care about timing.

---

**User**

ok, put that last curl command together with our endpoint:  https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com 

---

**Cursor**


Use this from the machine where your working `curl` runs:

```bash
curl -sS -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Content-Type: application/json" \
  -d '{
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
                      "query": "medicare",
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
  }' \
  -w '\nHTTP %{http_code}  total_time_sec %{time_total}\n'
```

That posts to `…/documents_text/_search` on your Serverless collection URL and appends status + total time after the JSON body. If production sets `OPENSEARCH_MATCH_DOCKET_BUCKET_SIZE`, replace `50000` with that value so it matches the app.

---

**User**

I am getting a 403 forbidden.  Any suggestions?

---

**Cursor**


A **403 from an `*.aoss.amazonaws.com` URL** almost always means **the request is not allowed to call that collection** — most often because **OpenSearch Serverless requires SigV4-signed requests** and/or your **principal is not allowed in the collection’s data access policy**. Unsigned `curl` usually fails with 403.

### 1. Sign the request (most likely fix)

From the EC2 box (so the instance role is used), try the same query with **`awscurl`** (install if needed: `pip install awscurl`):

```bash
awscurl --service aoss --region us-east-1 \
  -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"aggs":{"by_docket":{"terms":{"field":"docketId.keyword","size":50000},"aggs":{"matching_docs":{"filter":{"bool":{"should":[{"multi_match":{"query":"medicare","fields":["title","documentText"]}}],"minimum_should_match":1}}}}}}}' \
  -w '\nHTTP %{http_code}  total_time_sec %{time_total}\n'
```

If that works, plain `curl` without signing will keep returning 403.

### 2. Fix access in OpenSearch Serverless (if signing still returns 403)

- **Data access policy** on the collection must allow your caller (EC2 **instance role ARN**, or IAM user/role you’re using) — e.g. permissions like **`aoss:APIAccessAll`** on the collection/index, or the newer fine-grained equivalents for your setup.
- Confirm you’re using the **same AWS account** and **region** (`us-east-1`) as the collection.

### 3. Read the error body

Run once **without** `-s` (or add `-i`) and look at the JSON error message — it usually says whether it’s **signature/auth** vs **explicit deny** in policy.

```bash
curl -i -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Content-Type: application/json" \
  -d '{"size":0}'
```

**Summary:** Treat **403 on AOSS** as “not authenticated / not authorized” until you either **sign with SigV4 (`awscurl` or SDK)** or **add the right principal to the Serverless data access policy** (and ensure the request is actually signed if the API requires it).

---

**User**

I was wrong, we are using awscurl.  Give me the query using that command

---

**Cursor**


Use this on the EC2 instance (uses the instance role for SigV4):

```bash
awscurl --service aoss --region us-east-1 \
  -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Content-Type: application/json" \
  -d '{
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
                      "query": "medicare",
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
  }' \
  -w '\nHTTP %{http_code}  total_time_sec %{time_total}\n'
```

If production overrides `OPENSEARCH_MATCH_DOCKET_BUCKET_SIZE`, change `50000` to that value.

---

**User**

The -w switch doesn't work with awscurl.  I removed it and got what I needed by adding "time" to the front of the command.

There are two other indexes, and we run the same query against both.  One index is named "comments" and the other is named "comments_extracted_text."  Give me a bash script that takes the name of the index as a parameter and it makes the awscurl command against that index.  Then give me a script that calls this new script 3 times, once for each of the indexes.  Have this new script use time to print out how long each query takes.

---

**Cursor**


Checking for a `scripts` directory and the exact aggregation bodies for the comment indexes.




Creating two scripts: the app uses different query bodies per index (`multi_match` for `documents_text`; `match` on `commentText` / `extractedText` with nested `by_comment` aggs for the other two). Implementing that so each call matches production behavior.




Here’s what was added and how to use it.

### 1. `scripts/opensearch_text_match.sh`

- **Usage:** `scripts/opensearch_text_match.sh <index> [search_term]`
- **Indexes:** `documents_text`, `comments`, `comments_extracted_text` (anything else exits with an error).
- **Bodies:** Match `DBLayer._run_text_match_queries` in `db.py` (document index uses `multi_match` on `title`/`documentText`; the two comment indexes use `match` on `commentText` / `extractedText` plus the nested `by_comment` terms agg).
- **Endpoint:** Defaults to your AOSS URL; override with `OPENSEARCH_AOSS_ENDPOINT`.
- **Optional env:** `AWS_REGION` (default `us-east-1`), `OPENSEARCH_AOSS_SERVICE` (default `aoss`), `OPENSEARCH_MATCH_DOCKET_BUCKET_SIZE`, `OPENSEARCH_COMMENT_ID_TERMS_SIZE`.
- **Search term:** Escaped with Python so odd characters in `$TERM` stay valid JSON.

### 2. `scripts/time_all_opensearch_text_matches.sh`

- **Usage:** `scripts/time_all_opensearch_text_matches.sh [search_term]`
- Runs `time` on each of the three indexes in order and prints a header before each run.

**Examples**

```bash
chmod +x scripts/opensearch_text_match.sh scripts/time_all_opensearch_text_matches.sh   # if needed

./scripts/opensearch_text_match.sh comments medicare
./scripts/time_all_opensearch_text_matches.sh medicare
```

`time_all_opensearch_text_matches.sh` prints **three** timings (real/user/sys) — one per index — plus the large JSON response each time. If you only care about duration and not the body, you can change the inner script to send output to `/dev/null` or add a quiet flag later.

---

**User**

I am going to use both scripts in prod, and they will be in the same directory.  I don't need all the code to figure out ROOT and use it.

---

**Cursor**


Update applied: `time_all_opensearch_text_matches.sh` no longer sets `ROOT`; it calls `./opensearch_text_match.sh` in the current directory.

Run it from the folder that has both scripts, for example:

```bash
cd /path/to/that/dir
./time_all_opensearch_text_matches.sh medicare
```

---

**User**

for the @scripts/opensearch_text_match.sh  script, just error out if there aren't 2 parameters.  Use fixed value for the endpoint.  This is just for a quick test.  I don't need all the parameters.  Just put the curl command you gave me earlier in the script and substitute the index and search_term.

---

**Cursor**


Simplifying the script: require two arguments, a fixed endpoint, and `awscurl` with per-index bodies (documents vs comments differ).




Rewriting the script to require exactly two arguments, a hardcoded endpoint, and a compact Python helper to build the JSON bodies.




Here’s what changed:

### `scripts/opensearch_text_match.sh`

- **Requires exactly two arguments** — otherwise it prints `usage: …` and exits `1`.
- **Fixed endpoint:** `https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com`
- **Fixed `awscurl`:** `--service aoss`, `--region us-east-1`, `POST …/${INDEX}/_search`, JSON body.
- **No env-based options** — only a small **Python** block builds valid JSON for `documents_text`, `comments`, and `comments_extracted_text` (same shapes as before, with `50000` / `65535` baked in).

Example:

```bash
./opensearch_text_match.sh documents_text medicare
```

`time_all_opensearch_text_matches.sh` is unchanged: it still passes the index and term (`medicare` by default), so it satisfies the two-argument requirement.

---

**User**

No, I don't want python in this.  Just replace the index and search term in the curl command using $1 and $2, as needed.  

---

**Cursor**


Rewriting the script to pure bash: two required arguments, fixed endpoint, and a small bash `json_escape` so the search term stays valid JSON without Python.




Here’s what changed:

- **No Python** — bodies are built with `case` + `cat <<EOF` and **`$1`** in the URL (`…/$1/_search`) and **`$2`** embedded via **`Q="$(json_escape "$2")"`** so quotes/backslashes in the search term don’t break JSON.
- **Still exactly two arguments**; unknown **`$1`** prints an error and exits **1**.

`time_all_opensearch_text_matches.sh` is unchanged and still passes two arguments each run.

---

**User**

when I run the query against the two comments indexes it gives me back and error like:

{"error":{"root_cause":[],"type":"search_phase_execution_exception","reason":"","phase":"fetch","grouped":true,"failed_shards":[],"caused_by":{"type":"too_many_buckets_exception","reason":"Trying to create too many buckets. Must be less than or equal to: [65535] but was [65536]","max_buckets":65535}},"status":400}

is this a query problem or a problem in the way the index is configured?

---

**Cursor**


That message is almost always a **cluster-level aggregation limit**, not a bad mapping on the index.

### What it means

OpenSearch enforces **`search.max_buckets`** (often **65535** by default). A search may not create more than that many **aggregation buckets in total** across the whole response.

Your comments queries use:

1. A **`terms`** on `docketId.keyword` (up to **50 000** dockets), **and**
2. Under each docket, another **`terms`** on `commentId.keyword` with **`size`: 65535**.

Total buckets are not “50 000 + 65 535” — they scale with **how many docket buckets are actually built** and **how many comment buckets each one adds**. In practice that can **very quickly exceed 65 535**, or you can hit the limit in an edge case where the engine ends up with **65 536** buckets (e.g. right at the cap).

So:

| Interpretation | Answer |
|----------------|--------|
| **Index mapping wrong?** | Unlikely for this specific error; mappings don’t define `max_buckets`. |
| **Cluster / OpenSearch config?** | **Yes** — the hard ceiling is **`search.max_buckets`** (and related settings in some setups). |
| **Query too heavy for that limit?** | **Yes** — large nested `terms` aggs are exactly what trip this. |

### What you can do

1. **For your benchmark script**  
   Lower the inner `by_comment` `terms.size` (and/or the outer `by_docket` size) so total buckets stay **under** the cluster max (with margin), e.g. try **10 000** or **5 000** on the inner agg first.

2. **For production**  
   Either **raise** `search.max_buckets` (ops/cluster change, with care — more memory/CPU), or **change the approach** for huge cardinality (e.g. smaller caps, `composite` aggregations, or not counting every distinct `commentId` in one request).

3. **Align with the app**  
   The app uses `OPENSEARCH_COMMENT_ID_TERMS_SIZE` (default **65535**) and `OPENSEARCH_MATCH_DOCKET_BUCKET_SIZE` (default **50000**). Those defaults assume the cluster allows enough buckets; on a strict **65535** `max_buckets`, **nested** aggs like this are easy to break without raising the limit or lowering those sizes.

**Bottom line:** It’s a **limit imposed by OpenSearch** on aggregation size; your **query shape + sizes** are pushing past it. Fixing it is either **smaller aggs in the query** or **raising `search.max_buckets`** (and understanding the cost), not fixing the index mapping.

---

**User**

Ok, let's attack the problem of what we are trying to do:

First, can you infer the structure of each index from the code?

---

**Cursor**


Gathering index definitions and field usage from ingest code, docs, and search queries.




Here’s what the codebase implies about each index: **mappings** (from `db/ingest.py` `*_INDEX_BODY`, `db/ingest_opensearch.py`, and `docs/OpensearchInfo.md`) plus **how documents are written** and **what search uses**.

---

### Naming note

- **Search** (`DBLayer._run_text_match_queries` in `src/mirrsearch/db.py`) targets **`documents_text`**, **`comments`**, **`comments_extracted_text`**.
- **Docket ingest** (`db/ingest.py`) creates the index named **`documents`** (`OPENSEARCH_DOCUMENTS_INDEX`) with the same field shapes; **`db/ingest_opensearch.py`** also uses **`documents`** for its demo index. Production may use an alias or a separate index named `documents_text` (as in `docs/OpensearchInfo.md`).

---

### `documents_text` (and repo-local `documents`)

**Mappings (conceptually)**

| Field | Type | Notes |
|--------|------|--------|
| `docketId` | `text` + `.keyword` | Used in aggs as `docketId.keyword` |
| `documentId` | `text` + `.keyword` | Document id |
| `documentText` | `text` | Main body for full-text search |

`DOCUMENTS_INDEX_BODY` in `db/ingest.py` also adds a `.keyword` subfield on `documentText`; `ingest_opensearch.py`’s `documents` mapping only has `documentText` as plain `text` (no keyword on it).

**Ingest shape** (`ingest_htm_files` in `db/ingest.py`): `docketId`, `documentId`, `documentText` (from HTM). **Search** uses `multi_match` on **`title`** and **`documentText`**. Demo data in `ingest_opensearch.py` sometimes includes **`title`** on a document; the canonical mapping in `OpensearchInfo.md` for `documents_text` does **not** list `title`, so **prod may add `title` dynamically** or it may be missing—worth checking a live `_mapping`.

**One OpenSearch document per** regulation.gov **document** (`id` = `documentId`).

---

### `comments`

**Mappings**

| Field | Type | Notes |
|--------|------|--------|
| `commentId` | `text` + `.keyword` | Agg / cardinality as `commentId.keyword` |
| `commentText` | `text` + `.keyword` | Full-text search on **analyzed** `commentText` for `match` |
| `docketId` | `text` + `.keyword` | Bucket by docket as `docketId.keyword` |

**Ingest** (`_opensearch_comment_body` in `db/ingest.py`): `commentId`, `docketId`, `commentText` only. **One OpenSearch document per comment** (`id` = `commentId`).

---

### `comments_extracted_text`

**Mappings**

| Field | Type | Notes |
|--------|------|--------|
| `attachmentId` | `text` + `.keyword` | **Document `_id`** in ingest |
| `commentId` | `text` + `.keyword` | Links to comment |
| `docketId` | `text` + `.keyword` | |
| `extractedMethod` | `text` + `.keyword` | |
| `extractedText` | `text` + `.keyword` | Search uses analyzed `extractedText` for `match` |

**Ingest** (`_normalized_comments_extracted_text_body`): `docketId`, `commentId`, `attachmentId`, `extractedMethod`, `extractedText`. **One OpenSearch document per attachment** (extracted PDF/text blob), **`id` = `attachmentId`**—so a comment can have **multiple** rows if it has multiple attachments.

---

### How search uses this (same file)

- **`documents_text`**: `multi_match` on `title`, `documentText`; terms agg on `docketId.keyword`; inner filter agg `matching_docs`.
- **`comments`**: `match` on `commentText`; terms on `docketId.keyword`; nested terms on `commentId.keyword` under `matching_comments` (unique comment ids per docket).
- **`comments_extracted_text`**: `match` on `extractedText`; same docket + `commentId` pattern under `matching_extracted`.

So structurally: **documents** are per **documentId**, **comments** per **commentId**, **extracted text** per **attachmentId**, all tied together with **`docketId`** (and **`commentId`** on the two comment-related indices).

---

**User**

Good.  This is how I understand it as well.

Let's talk about the documents_text query first.  For that one, we want to take the term or terms that the user gives us and figure out how many documents in the docket match.  All we need is a count, we don't need to determine how well the document matches.  Right now, I believe the code is written so that we just get back a list of documents that match (and lots of other information), and then we do aggregation in memory.

I want to explore pushing as much as the work into open search as possible.  Ideally, we have a query where we pass the search terms, and it returns a list of docket ids and the number of documents that match.

Something like function-like pseudo-code:

query_document_text(search_terms) -> list of {docketid, count}

Can opensearch perform queries like this?



---

**Cursor**


Yes. OpenSearch (Elasticsearch-style APIs) is built for exactly this: **restrict the corpus with your text clause, then aggregate so each bucket is a `docketId` and the bucket’s document count is how many documents matched.**

### What you want

`query_document_text(search_terms) -> [{ docket_id, count }, ...]`

That maps to: **`size: 0`** (no hits returned), a **`query`** that encodes the user’s terms, and an aggregation that **groups by `docketId.keyword`** and uses **`doc_count`** (implicit in each `terms` bucket) as the per-docket match count.

Conceptually:

```text
POST documents_text/_search
{
  "size": 0,
  "query": { ... multi_match / bool over user's terms on title + documentText ... },
  "aggs": {
    "by_docket": {
      "terms": {
        "field": "docketId.keyword",
        "size": 50000
      }
    }
  }
}
```

Each bucket in `by_docket.buckets` is `{ "key": "<docketId>", "doc_count": <n> }` where **`doc_count` is the number of indexed documents in that docket that satisfied the query**. You do **not** need per-hit scoring for that; a plain `bool` / `multi_match` query is enough.

You can also add **`min_doc_count`** (e.g. `1`) if you want to be explicit; default behavior already drops empty buckets.

### How this relates to your current code

In `DBLayer._build_docket_agg_query`, the request uses **`size: 0`** and **aggregations only**—it is **not** returning a list of matching documents to the app. The heavy work is already in OpenSearch. The structure there is **terms on every docket** with a **nested `filter` agg** that re-applies the same match inside each bucket. That still avoids returning individual docs, but it can be **more expensive** than necessary because the outer `terms` can be built over the **whole** index depending on how the request is structured.

A common optimization for your goal is: **put the text match in the top-level `query`**, then use a **single** `terms` aggregation on `docketId.keyword` on that filtered set. That directly answers “how many matching documents per docket?” with one aggregation over **only** matching documents.

### Multi-term / boolean behavior

You can mirror whatever product rules you need with `bool` (`should` / `must` / `minimum_should_match`) and one `multi_match` per phrase or term. OpenSearch does not need to return scores to the client; you only read aggregation buckets.

### Limits to be aware of

- **`terms` `size`**: caps how many docket buckets you get (same tradeoff as today with `OPENSEARCH_MATCH_DOCKET_BUCKET_SIZE`).
- **Very high-cardinality docket lists**: if you ever need *all* dockets with no practical cap, you’d use **`composite`** aggregation and page—still server-side, just a different API.

**Bottom line:** Yes—OpenSearch can return **`docketId` + document match count** entirely server-side; the natural shape is **query + `terms` agg on `docketId.keyword`** with **`size: 0`**, and optionally tightening the current query so the text filter applies **once** at the top level instead of inside every docket bucket.

---

**User**

There are about 250K dockets that hold about 2M documents.  If someone does a search for a common term - e.g. "government" - it is concievable that every document would match.  Is this what would trigger the bucket issue?  If so, is there a way to manage this?

A second question:  While I don't want to return quality of match, this may be a way to sort the data.  Overall, we need to figure out how to sort results.  order by date isn't right because recent dockets with 1 match shouldn't occur before older dockets with lots of matches.  At the same time, a docket from 2-3 years ago with a lot of matches generally isn't as vaulable as a more recent docket with fewer matchs.  It's a balance between the two.  What features does Open search have that can help with this?

---

**Cursor**


## 1. Common terms, 2M docs, and bucket limits

**What actually drives bucket pressure**

- A **`terms` aggregation on `docketId.keyword`** creates **one bucket per distinct docket** in the result set (up to `size`), **not** one bucket per document.
- So if “government” matches **all ~2M documents** spread across **~250K dockets**, you’re asking for on the order of **250K docket buckets**, not 2M.

**Is that what triggers the bucket issue?**

- **`search.max_buckets`** (often **65,535** by default) caps the **total number of aggregation buckets** in the response.
- A single `terms` agg with **`size`: 250,000** can by itself **exceed** that limit, even with **no** nested sub-aggs.
- So yes: a broad query that matches the whole corpus can still force you to **materialize a huge number of docket buckets** if you want **every** docket represented.

**Ways to manage it**

| Approach | Idea |
|----------|------|
| **Raise `search.max_buckets`** | Lets one response return ~250K+ buckets; **more heap / risk** — ops decision. |
| **`composite` aggregation** | **Page** through dockets (`after` key): many small responses, each under the cap; best when you must enumerate everyone. |
| **Lower `terms.size` / product cap** | “Top N dockets by match count” only — **incomplete** but cheap; define N from UX. |
| **Narrow before aggs** | Extra filters (agency, date window, etc.) if the UI allows — **fewer** dockets in play. |
| **Hybrid** | OpenSearch returns candidates + counts; **Postgres** or app does final ordering/paging if you already join there anyway. |

So the problem isn’t “2M documents” by itself; it’s “**how many docket buckets** must we build in **one** search response?”

---

## 2. Sorting: match volume vs recency

OpenSearch doesn’t give you one magic “importance” knob for **docket-level** ranking out of the box, but it gives **building blocks**. You usually combine **full-text** with **structured fields** (especially a **date** on the document or denormalized **docket** date).

**Useful features**

1. **`terms` aggregation with `order`**  
   - e.g. **`_count` descending** → dockets with **more matching documents** first.  
   - Pure **volume**; no time signal unless you add more.

2. **Sub-aggregation + `bucket_sort` (pipeline)**  
   - Per docket: `doc_count`, and e.g. **`max`** or **`min`** on a date field (`postedDate`, `docketModifyDate`, etc.).  
   - **`bucket_sort`** can sort buckets by **multiple keys** (e.g. count then date, or a **script** combining both) — **if those fields exist in the index**.

3. **Function score / `script_score`** (document-level)  
   - Blend **text score** with **recency** via **decay functions** (`gauss` / `exp` / `linear`) on a date field, or a **script** that weights count-like signals.  
   - Often paired with **`collapse`** on `docketId` if you still return hits, not only aggs — more moving parts.

4. **Denormalized docket metadata in each document**  
   - To rank by “recent docket” in OpenSearch, each doc (or a docket rollup) typically needs something like **`docket_modify_date`** (or similar) **indexed** and **mapped as `date`**.  
   - If that only lives in Postgres, a **practical pattern** is: OpenSearch returns **`{ docketId, match_count }`**, app or DB applies **`f(count, modify_date)`** — full control over the tradeoff.

**Design pattern for your “balance”**

- **Define explicitly** something like  
  `score = w1 * g(match_count) + w2 * h(recency)`  
  with `g` often **log** (diminishing returns for huge counts) and `h` from **days since modify** or similar.
- **OpenSearch** can help if **`match_count` per docket** comes from aggs and **date** is on the document; then **bucket_sort** + script or two-phase sort.  
- If the formula changes often, **doing the blend in application code** after fetching counts + dates is often **simpler to tune** than encoding policy in cluster scripts.

**Takeaway:**  
- **Bucket explosion** for common terms is about **how many docket buckets** you ask for in **one** request — **composite** paging or **raising `max_buckets`** (or capping N) are the main levers.  
- **Ranking** benefits from **indexed dates** + **`bucket_sort`** / pipelines, or from returning **counts from OpenSearch** and **merging with Postgres dates** for a clear, tunable **`f(count, recency)`**.

---

**User**

Ok, for the bucket issue, can we say something like:  process data from newest to oldest, if you ever exceed 65K, drop the data with the fewest matches.  In practice, no one is going to look at 65K results (if possible, we could reduce that size if it helps performance).  If the number gets too small, we risk missing out "good" results, but I think a large bucket count avoids that from being an issue.

Basically, I'm looking for a way to not change the bucket count limit, manage efficiency, and make sure we can get results.

---

**Cursor**


Here’s a tight way to think about it and what OpenSearch can actually do.

## What “65K” really limits

`search.max_buckets` caps **aggregation buckets in one response**, not “documents scanned.” So your lever is: **how many docket buckets** you ask OpenSearch to **materialize** in that response.

The good news: you don’t need a separate “drop the smallest” pass if you **never ask for more than N buckets**. You choose **N ≤ 65K** (with a little margin, e.g. **50k–60k**) and an **order** that encodes your policy. OpenSearch only returns **that many** buckets, in that order — the rest are simply **not included** (not “lost” from the cluster, just not returned).

So you’re not fighting the limit if you set **`terms.size`** (and any nested aggs) so **total buckets stay under** the cap.

## “Newest first, then drop the weakest” — two different orderings

Those are **two different sort keys**:

1. **Fewest matches dropped first** → order by **`_count` descending** (keep dockets with the **most** matching documents).
2. **Newest first** → you need a **date** on documents (or denormalized per doc), then e.g. a **`max`** (or **`min`**) sub-aggregation on that field per docket, and order buckets by that.

You **cannot** get “always newest globally, and among those drop lowest counts” from a single simple `terms` order unless you encode **one** sort key (e.g. a **script** or **pipeline** that combines date + count). The usual product split is:

- **Pick one primary sort** in OpenSearch (e.g. **recency** or **match count**), **`size: 50000`**, **under** `max_buckets`, **or**
- **Hybrid in the app**: OpenSearch returns **counts** (and maybe dates if indexed); you compute **`f(count, date)`** and sort/paginate there.

## A practical pattern that matches your goals (no raising the limit)

**Single `terms` aggregation on `docketId.keyword`:**

- **`size`**: e.g. **50 000** or **60 000** (stay **below** 65 535 so you’re safe if anything adds a few extra buckets).
- **`order`**: choose the policy you care about most:
  - **Volume-first**: `"order": { "_count": "desc" }` — “drop” (omit) dockets with **fewer** matches first, in the sense that only the top **N** by count are returned.
  - **Recency-first**: add a **`max`** sub-agg on a date field, then order by that metric descending (exact syntax depends on OpenSearch version; sometimes you need a **`bucket_sort`** pipeline for multi-key ordering).

That **is** “we’re not returning 250k buckets; we cap at N and only return the best N by the chosen metric.”

## “Process newest to oldest” as *scan* order

OpenSearch doesn’t stream the index “newest to oldest” for free in a way that changes **`terms`** behavior. **Time ordering** has to show up as **field values + aggregation order** (or a **filter** on a date range: “only last 2 years,” then aggregate — often **fewer** dockets, easier to stay under 65K).

## Nested comment aggs (your earlier 403)

If **comment** queries use **nested** `terms` (docket × commentId), **total buckets multiply**. Trimming the **outer** `terms.size` helps, but you must also keep **inner** `terms.size` small enough that **docket_buckets + (docket × comment_buckets)** doesn’t exceed **`max_buckets`**. That’s separate from the “250k dockets” story.

## Short answer

- **Yes**, you can stay at the default bucket limit by **capping** how many docket buckets you request (**`terms.size` ≤ ~60k**) and **ordering** so you keep the “best” dockets by **match count** and/or **date** (if indexed).
- **“Drop fewest matches”** maps naturally to **`order: _count desc`** + **`size: N`**.
- **“Newest first”** needs a **date** in the index and an **order** (or filter) on that; combining **both** with strict fairness usually means **scripted `bucket_sort`**, **composite** paging, or **app-side** ranking after OpenSearch returns **counts + dates**.

If you tell me whether **docket-level modify date** exists on each document in `documents_text`, we can narrow this to one concrete agg shape (count-first vs date-first vs two-phase).

---

**User**

Ok, so the bucket issue is about RESULTS not intermiediate work.  Opensearch will hold all 250K buckets (dockets) as possible results if necessary - but it will never return more than 65K results?  Is that right?  If so, I have not problem with limiting the number of search results.  As I said, no user is ever going to page through that many results.

---

**Cursor**


Not quite — worth splitting two different knobs.

### What `search.max_buckets` (~65K) actually does

It is a **hard cap on the total number of aggregation buckets** OpenSearch is allowed to **build and return** in **one** search response (including **nested** sub-aggregations).  

If the query would need **more** than that many buckets **total**, the request typically **fails** with `too_many_buckets_exception` — it does **not** “compute all 250K dockets internally and then only return 65K.”

So it’s not a **“results window”** on top of unlimited intermediate work; it’s a **ceiling** on how large the **aggregation result tree** is allowed to get. Cross it → **error**, not a trimmed list.

### What *you* control: `terms` `size` (and nested `size`s)

For a `terms` aggregation on `docketId`, **`size`** is “at most this many **docket** buckets” (given how `terms` works on shards, often **approximate** for very high cardinality, but the important part is you’re **asking** for a bounded number).

If you set something like **`size: 50000`** and you don’t have other aggs exploding bucket count, you stay **under** `max_buckets` and you get **up to** 50K dockets — which matches what you want product-wise.

### How this fits what you said

- **Limiting how many docket “results” you care about** (e.g. top 50K by match count or by date) is exactly how you **stay efficient** and **avoid** hitting the cluster limit — by **never requesting** a 250K-bucket `terms` in one shot.
- **You’re not relying** on OpenSearch to silently drop from 250K → 65K; you **set** `size` (and nested sizes) so the **total bucket count stays safe**.

**Bottom line:** The 65K limit is about **maximum buckets per response** (failure if exceeded), not “hold 250K, return 65K.” Limiting search results with a modest **`terms.size`** (and keeping nested aggs small) is the right mental model — and it’s aligned with “no one will page through that many.”

---

**User**

How does the number of search terms impact the bucket issue?  Is this something we need to worry about?  For example, if the user types 20 search terms, are we more likely to hit the bucket limit?  Also, how is does opensearch handle a list of terms like this - is it AND logic, OR logic, or something else?  Is this controllable - and does the current code use one form or another?

---

**Cursor**


Checking how `text_match_terms` builds queries for multiple list entries and the `multi_match` settings.




## Does more search terms mean more buckets?

**No.** The bucket count is driven by the **aggregation shape** (e.g. how many `terms` buckets on `docketId`, and for comments how many nested `terms` on `commentId`), **not** by how many clauses sit inside the inner `bool` filter.

Adding more `match` / `multi_match` clauses only adds **siblings** under one `bool` — it does **not** add extra aggregation buckets per clause.

So **20 strings** in the `terms` list → **20** query clauses in one `bool` → **same** bucket structure as **1** string; you are **not** more likely to hit `max_buckets` because of “20 terms” by itself.

What *can* change with more/broader clauses is **work**: more clauses to evaluate and often **more documents** matching the filter (wider hits), which can affect **latency and memory**, but not the **number of docket buckets** your `terms` agg asks for.

**Today’s API path:** `InternalLogic` calls `text_match_terms([(query or "").strip()])`, so you pass **one** list element — the **whole** user query as a **single** `multi_match` / `match` `query` string, not 20 separate list items.

---

## AND vs OR — how OpenSearch treats “a list of terms”

There are **two different** situations:

### 1) Multiple entries in the Python list: `text_match_terms(["a", "b", "c"])`

The code builds one clause per string and wraps them in:

```285:302:src/mirrsearch/db.py
    def _build_docket_agg_query(agg_name: str, match_clauses: List[Dict]) -> Dict:
        """Build a docket-bucketed aggregation query with an inner filter."""
        return {
            "size": 0,
            "aggs": {
                "by_docket": {
                    "terms": {
                        "field": "docketId.keyword",
                        "size": _opensearch_match_docket_bucket_size(),
                    },
                    "aggs": {
                        agg_name: {
                            "filter": {
                                "bool": {
                                    "should": match_clauses,
                                    "minimum_should_match": 1
                                }
                            }
                        }
                    }
                }
            }
        }
```

`should` + `minimum_should_match: 1` means **OR**: a document matches if **any** of those clauses matches. Same idea for the comment queries in `_build_docket_agg_query_unique_comments`.

### 2) One string with several words: `text_match_terms(["foo bar baz"])`

That is **one** `multi_match` / `match` with `query: "foo bar baz"`. The string is **analyzed** into tokens; for a normal `match` / default `multi_match`, OpenSearch typically uses **`operator: or`** between those tokens unless you set **`operator: "and"`**. The current code does **not** set `operator`, so you get the **default** (usually **OR** between analyzed terms).

---

## Is it controllable?

Yes: e.g. `operator: "and"` on `match` / `multi_match`, or use a `bool` with `must` instead of `should`, or tune `minimum_should_match` for `bool` queries.

---

## Do you need to worry?

- **Bucket limit:** not because of “20 terms” as **extra buckets**; worry about **`terms` `size`**, **nested** aggs, and **`search.max_buckets`** as already discussed.  
- **Behavior:** if you care whether the user means **all words** vs **any word**, you should **decide explicitly** and set **`operator`** / **`bool`** accordingly — right now the **list-of-strings** path is **OR**, and the **single multi-word string** path follows **match** defaults (typically **OR** between tokens).

---

**User**

Good.  I am understanind this better now.

the next topic is database efficiency:  in a sql DB we create indexes to speed up queries.  Does open seach have an equivalent concept, and if so what should we have to suppor this query.  At this time, this is the ONLY query I expect to touch this index.

Alternatively, is there a better way to store the data in open search to facilitate this query?

---

**Cursor**


OpenSearch doesn’t use “indexes” the way SQL does, but it has **analogous mechanics**: what gets indexed, how it’s stored, and how queries use it.

## What corresponds to a SQL index?

| SQL idea | OpenSearch analogue |
|----------|---------------------|
| Index on a column for fast lookup | **Inverted index** on **analyzed** `text` fields (automatic; that’s how `match` / `multi_match` work). |
| Index for grouping/joins/sorts | **`keyword`** fields use **doc values** (and ordinals for `terms` aggs); good for **`terms` aggregations** on `docketId` / `commentId`. |

There is no separate `CREATE INDEX` statement for full text—the **mapping** (`text` vs `keyword`, analyzers, subfields) **is** the definition of how things are indexed.

## What your query actually needs (documents index)

For “text match + count per docket” you use:

1. **Full-text** on `title` / `documentText` → **`text`** (analyzed) → inverted index.
2. **Bucket by docket** → **`docketId.keyword`** (or a dedicated `keyword` field) → doc values / ordinals for **`terms`** aggs.

Your existing mapping pattern (`text` + multi-field **`keyword`** for ids) is exactly what this pattern expects. You do **not** need an extra “index” beyond a sensible mapping.

## If this is the only query

You can tune **mappings and settings**, not add a second “OpenSearch index” on the same data:

- **Query only fields you need** — if `title` is never populated, you could drop it from `multi_match` or from ingest to shrink the inverted index.
- **`index: false`** on stored fields you never search/aggregate (saves CPU/disk on those fields).
- **`doc_values: false`** on `text` fields you only search, not sort/agg (saves space; default for `text` is often already lean for aggs).
- **High-cardinality `terms` on `docketId`** — optional **`eager_global_ordinals: true`** on that `keyword` field can speed repeated **`terms`** aggs (uses more heap). Tradeoff: memory vs speed.
- **Shards/replicas** — fewer shards if the index is modest; avoids coordination overhead (ops tuning, not mapping).

None of that is mandatory for correctness; it’s **performance tuning**.

## Is there a “better” way to store the data?

For “**how many documents per docket match this text**?” the usual and good model is what you have:

- **One OpenSearch document per regulation.gov document** (per `documentId`), with **`docketId`** on each row, **text** on the body.

Alternatives are usually **worse** for this query:

- **One doc per docket with all text concatenated** — you lose **per-document** counts unless you encode something else; huge fields, worse updates.
- **Nested** docs — useful for parent/child constraints; adds complexity; not needed for a flat “count docs per docket” story.

So: **keep one document per source document**, **`docketId` as `keyword`** for aggs, **`text`** for the match query.

## Short answers

- **Equivalent to SQL indexes:** **inverted index** for `text` (search), **keyword + doc values** for **`terms`** on `docketId` (and `commentId` where used).
- **What to have:** mappings that keep **`text`** on searchable content and **`keyword`** on `docketId` (and `commentId` for comment indices); align field names with the query.
- **Better storage model:** for this access pattern, **your current shape is appropriate**; optimize with mapping/settings and cluster tuning rather than a radically different layout unless requirements change.

---

**User**

Taking all this together, give me a query I can run against the documents_text index.  It should allow for multiple search terms and ensure that we don't exceed the bucket limit.  For the search, use the use the weighted "balanced" version of scores.  Use fixed values that you think make sense - I can always tune them later.

Give me the result as a awscurl command that I can try on my EC2 instance.  Put everything in a new script in the scripts folder.  The parameters to the script should each be a search term (i'll surround them in double quotes for a multi-word term).

If something in my description doesn't fit with what we discussed, point out issues and ask for clarification before you write the script.

---

**Cursor**


Checking the existing script for endpoint and escaping patterns, then adding the new script.




Noting: with `size: 0`, per-docket `doc_count` is unchanged by `tie_breaker` and field boosts — they only affect `_score`. Matching is still determined by the `bool`/`multi_match` clauses. Including balanced `multi_match` as requested for consistency and future use (e.g., hits or score-based ordering). Documenting that in the script header.




Fixing BODY assignment: `read -r -d ''` is unreliable here. Verifying JSON construction:




Here’s what was ambiguous and how it was handled, then what was added.

### Clarifications / assumptions

1. **`"Weighted balanced" scores`** — Implemented as Elasticsearch/OpenSearch **`multi_match`** with **`type`: `best_fields`**, **`tie_breaker`: `0.3`**, and **`title^2`** + **`documentText`** (title boosted 2×). That’s the usual “blend fields with a tie-breaker” setup.

2. **Multiple CLI args** — Treated as **separate phrases**, combined with **`bool.should`** + **`minimum_should_match`: 1** → **OR** between phrases (same idea as your existing `text_match_terms` when given several strings).

3. **Phrases vs words inside a phrase** — For each argument, **`operator`: `"or"`** applies to **tokens** after analysis (default-style OR). Use **one quoted argument** for a phrase you want as a single `multi_match` **query** string (e.g. `"part d"`).

4. **`size`: 0** — **`tie_breaker` / boosts only change `_score`**, not which docs are counted. **Per-docket `doc_count` is the same** as without `tie_breaker` for the same `bool` (no `min_score`). The script still uses balanced `multi_match` as you asked; the header comment explains this.

5. **Bucket cap** — **`terms.size`: `50000`**, **`shard_size`: `55000`**, **`order`: `_count` desc** — stays under **`search.max_buckets`** and matches “limit results, nobody pages 65k.”

6. **`track_total_hits`: true** — Lets you see total matching docs in the response; remove if you want less work on huge matches.

### New script

**`scripts/documents_text_balanced_search.sh`**

- **Usage:** `./documents_text_balanced_search.sh <term> [term ...]`  
  Example: `./documents_text_balanced_search.sh medicare "part d" government`
- **Requires:** `awscurl`, IAM on the instance (same as your other scripts).
- **Endpoint / index:** Same AOSS URL as before, index **`documents_text`**.

**Equivalent `awscurl` (one phrase):**

```bash
awscurl --service aoss --region us-east-1 \
  -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"track_total_hits":true,"query":{"bool":{"should":[{"multi_match":{"query":"medicare","fields":["title^2","documentText"],"type":"best_fields","tie_breaker":0.3,"operator":"or"}}],"minimum_should_match":1}},"aggs":{"by_docket":{"terms":{"field":"docketId.keyword","size":50000,"shard_size":55000,"order":{"_count":"desc"}}}}}'
```

If you instead want **AND** between phrases (`must` / all terms required), say so and the script can be switched. If **`title`** is missing on many docs in prod, matches rely mainly on **`documentText`**; that’s a data issue, not the query shape.

---

**User**

when I run the query I get back a single blank line.  I tried it with the script and the direcdt awscurl command.

---

**Cursor**


Inspecting the script and tracing likely causes of empty output:




Investigating: awscurl prints `response.text`; an empty body produces `print('')` — one newline — matching "a single blank line." Checking header handling: passing only `-H Content-Type` may interact badly with awscurl defaults. Verifying and fixing the script.




Identifying the cause: awscurl ends with `print(response.text)`. An empty response body prints only a newline — matching “a single blank line.” Likely causes: HTTP error with empty body, wrong signing/service, or missing `Accept` header. Adding explicit `Accept: application/json`, removing `exec` so errors surface, and adding brief troubleshooting.





Here’s what’s going on and what we changed.

## Why you see “one blank line”

`awscurl` ends with **`print(response.text)`** (see [awscurl.py](https://github.com/okigan/awscurl/blob/master/awscurl/awscurl.py)). If the HTTP **body is empty**, `response.text` is `""` and Python prints **only a newline** — exactly **one blank line**.

So this is almost always: **HTTP response with an empty body** (not “OpenSearch returned JSON you can’t see”).

Typical causes:

| Cause | What to check |
|--------|----------------|
| **Wrong HTTP status** | **403/401** (auth / data access policy), **404** (wrong path/index), **405** (GET vs POST). |
| **Signing / URL** | `--service aoss`, **`us-east-1`**, full **`…/documents_text/_search`**. |
| **Headers** | Prefer **`Accept: application/json`** and **`Content-Type: application/json`** together. |

## What we changed in the script

1. **Removed `exec`** so failures aren’t harder to trace.
2. **Set both headers** on every request:
   - `Accept: application/json`
   - `Content-Type: application/json`  
   (If you hand-roll `awscurl` with **only** `-H Content-Type`, you don’t get awscurl’s built-in defaults; being explicit avoids odd server behavior.)
3. **Abort if the built body is empty** (sanity check).
4. **Short troubleshooting note** in the script header.

## What to run on EC2

**See status and headers:**

```bash
awscurl -v --service aoss --region us-east-1 \
  -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"query":{"match_all":{}}}'
```

`-v` prints the request/response to **stderr**; the JSON body is still on **stdout**. If stdout is still empty, check **stderr** for the HTTP status line.

**Include headers on stdout** (so you see `HTTP/2 403` etc. next to the body):

```bash
awscurl -i --service aoss --region us-east-1 \
  -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"query":{"match_all":{}}}'
```

If you get **403**, the body might still be JSON or empty depending on the gateway — **`-v` / `-i`** is what turns “blank line” into a real diagnosis.

After pulling the updated **`documents_text_balanced_search.sh`**, run it again; if it’s still blank, run the **`match_all`** one-liner above. If **`match_all`** returns JSON but your script doesn’t, the problem is in the **request JSON**; if **`match_all`** is also blank, focus on **auth / URL / region / service**.

---

**User**

[ec2-user@ip-172-31-14-26 ~]$ awscurl -v --service aoss --region us-east-1 \
  -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"query":{"match_all":{}}}'
{'access_key': None,
 'data': '{"size":0,"query":{"match_all":{}}}',
 'data_binary': False,
 'fail_with_body': False,
 'header': ['Accept: application/json', 'Content-Type: application/json'],
 'include': False,
 'insecure': False,
 'location': False,
 'output': '',
 'profile': 'default',
 'region': 'us-east-1',
 'request': 'POST',
 'secret_key': None,
 'security_token': None,
 'service': 'aoss',
 'session_token': None,
 'uri': 'https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search',
 'verbose': True}
"Credentials file '/home/ec2-user/.aws/credentials' exists 'False'"
'loading botocore package'
''
('\n'
 'CANONICAL REQUEST = POST\n'
 '/documents_text/_search\n'
 '\n'
 'content-type:application/json\n'
 'host:fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com\n'
 'x-amz-content-sha256:ea835f2830c28623ce71c1ae128e004d5366c324924fe3db14e0e2a92094836e\n'
 'x-amz-date:20260417T214847Z\n'
 'x-amz-security-token:IQoJb3JpZ2luX2VjEBYaCXVzLWVhc3QtMSJGMEQCIA5z/HCOQBws2cWuciOxCe6DIv6e9ZN8VZfquPuozrv4AiBUI/ALmRaQ+yo1lQtM1hIE0LgCj3V01p7n0EVRv5vUiiq7BQjf//////////8BEAUaDDkzNjc3MTI4MjA2MyIMdiPfmc69jLDH6xmeKo8F95/n/yg1yk0qFdQe4UxiQj6w64CaYCXeQjbVFyTkLCG2lV7Nehez1ZJZHK6cPoaA/uV3BggadoYIOPuuDd9LmyaVw2w0C+dWb/Vj2EOpSH92gV5tM7UkPkcclCM5Qv1l1nvceO9F8OB7QL5YkY/Cjj7reZ//4qk/5pg69f0ueU9S+dvN8WQGCblmLADUk73M47LeAE1RayLX57Y+tBg3P2gx5waMy0rrNWCLZqz56jKuSwkimaFV8X3MCEY8i7kaCoHWdnFEJlL3bDweBdMvZiZIyITQpbdQ1Wp4eiDa3/QBc1LE1ofzgan/S9Bg+1Hbmx9SYqcLmNIswHRmwe0FBPSoO5BRYw+rcI8uCjtWDGiYMuATfcB1taaMU3olF1UtCQ0r5fE5XPcXREtAPdhONg2IyPcGS0tXl3IRc85hqfj/jrqx3wrG0RbjceBnHOKYgEIYLd23IvmvHFsXnO3tRJEIL7iOwTzZQJHxfPXfzAD9j/aEw+1nB8k1BFPLuwxE3vJCgol3fdrxj7Ef53n5rUi0LOIGICpBRM7daYFcIHUIG7RYyRlZOJg0c713UGFbzthc8BVthvt6S9mgnJKqSEHVomAw2jLI7BPS4Rjlktx/yV19pi9KPoUq7YhgT8jJut96wWi8Fyl9zNaJI31sUOguOFf1hMHnEppWIziN9qVqBg56kCOsm09xpEfQQ/X2Y9GguAE7NGD0DVNxVII6nB9OsUtSNlXI/pri2dbfKbh8e90DHXbdz6vNyRWjeq2ftjpBKzT6m2rRpVaMoZTVu/TzD9Y2Nl8Uphoz0z1qqnLHbgALSFgBVBw37kXQYUAPOAkg2/CaD3/Sr+lISTMvjv+cvRJusiTOUQCxwNUgtTDq0YrPBjqyAb4+P21D8w/MaueDWaua9g8JxzirFakr/JjF8veWq02IB5Y2NxKKzPWcM1zf/92q6mCyRwYBC2cAFSXoUqFrKHDPAoF1mIaAM+TFQfXMnITQbivAxlILmZH26nkp2esQmExEovmNW8LJWJigc3ewp+oClr5DrRgYlOgM1qXAWZjQHoxAVsnHKwNa+4nOFVD0oUjciXcJjE7Zwsm3tKpe8ifObn8Bdcf94MDG2bx7x/3LkV4=\n'
 '\n'
 'content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token\n'
 'ea835f2830c28623ce71c1ae128e004d5366c324924fe3db14e0e2a92094836e')
('\n'
 'STRING_TO_SIGN = AWS4-HMAC-SHA256\n'
 '20260417T214847Z\n'
 '20260417/us-east-1/aoss/aws4_request\n'
 '12aca8ea989c5ccbad8f74aff6f3a779f3890e4c1deb3c3afe1e395715ace77a')
'\nHEADERS++++++++++++++++++++++++++++++++++++'
{'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': 'AWS4-HMAC-SHA256 Credential=ASIA5UG7LMSH2BJKZQS7/20260417/us-east-1/aoss/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=f9fccc0964cb109f825a14efad1cb37d978a6553cacc824033ad4e7235f6826a', 'x-amz-date': '20260417T214847Z', 'x-amz-content-sha256': 'ea835f2830c28623ce71c1ae128e004d5366c324924fe3db14e0e2a92094836e', 'x-amz-security-token': 'IQoJb3JpZ2luX2VjEBYaCXVzLWVhc3QtMSJGMEQCIA5z/HCOQBws2cWuciOxCe6DIv6e9ZN8VZfquPuozrv4AiBUI/ALmRaQ+yo1lQtM1hIE0LgCj3V01p7n0EVRv5vUiiq7BQjf//////////8BEAUaDDkzNjc3MTI4MjA2MyIMdiPfmc69jLDH6xmeKo8F95/n/yg1yk0qFdQe4UxiQj6w64CaYCXeQjbVFyTkLCG2lV7Nehez1ZJZHK6cPoaA/uV3BggadoYIOPuuDd9LmyaVw2w0C+dWb/Vj2EOpSH92gV5tM7UkPkcclCM5Qv1l1nvceO9F8OB7QL5YkY/Cjj7reZ//4qk/5pg69f0ueU9S+dvN8WQGCblmLADUk73M47LeAE1RayLX57Y+tBg3P2gx5waMy0rrNWCLZqz56jKuSwkimaFV8X3MCEY8i7kaCoHWdnFEJlL3bDweBdMvZiZIyITQpbdQ1Wp4eiDa3/QBc1LE1ofzgan/S9Bg+1Hbmx9SYqcLmNIswHRmwe0FBPSoO5BRYw+rcI8uCjtWDGiYMuATfcB1taaMU3olF1UtCQ0r5fE5XPcXREtAPdhONg2IyPcGS0tXl3IRc85hqfj/jrqx3wrG0RbjceBnHOKYgEIYLd23IvmvHFsXnO3tRJEIL7iOwTzZQJHxfPXfzAD9j/aEw+1nB8k1BFPLuwxE3vJCgol3fdrxj7Ef53n5rUi0LOIGICpBRM7daYFcIHUIG7RYyRlZOJg0c713UGFbzthc8BVthvt6S9mgnJKqSEHVomAw2jLI7BPS4Rjlktx/yV19pi9KPoUq7YhgT8jJut96wWi8Fyl9zNaJI31sUOguOFf1hMHnEppWIziN9qVqBg56kCOsm09xpEfQQ/X2Y9GguAE7NGD0DVNxVII6nB9OsUtSNlXI/pri2dbfKbh8e90DHXbdz6vNyRWjeq2ftjpBKzT6m2rRpVaMoZTVu/TzD9Y2Nl8Uphoz0z1qqnLHbgALSFgBVBw37kXQYUAPOAkg2/CaD3/Sr+lISTMvjv+cvRJusiTOUQCxwNUgtTDq0YrPBjqyAb4+P21D8w/MaueDWaua9g8JxzirFakr/JjF8veWq02IB5Y2NxKKzPWcM1zf/92q6mCyRwYBC2cAFSXoUqFrKHDPAoF1mIaAM+TFQfXMnITQbivAxlILmZH26nkp2esQmExEovmNW8LJWJigc3ewp+oClr5DrRgYlOgM1qXAWZjQHoxAVsnHKwNa+4nOFVD0oUjciXcJjE7Zwsm3tKpe8ifObn8Bdcf94MDG2bx7x/3LkV4='}
'\nBEGIN REQUEST++++++++++++++++++++++++++++++++++++'
('Request URL = '
 'https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search')
'\nRESPONSE++++++++++++++++++++++++++++++++++++'
'Response code: 401\n'
{'x-request-id': 'bb5448eb-9066-9349-9548-034d42d9733e', 'x-aoss-response-hint': 'X01:network-policy-deny', 'date': 'Fri, 17 Apr 2026 21:48:46 GMT', 'server': 'aoss-amazon', 'content-length': '0'}
''



Someone changed the network settings (independent of this work).  Does this response mean that we aren't getting to the Open Search instance?

---

**Cursor**


You **are** reaching **Amazon OpenSearch Serverless (AOSS)**. This is not a generic “host unreachable” or DNS failure.

What the response shows:

| Signal | Meaning |
|--------|--------|
| **`Response code: 401`** | The service rejected the request as **unauthorized** for this access path. |
| **`server: aoss-amazon`** | The response came from **AOSS**, not some random proxy. |
| **`x-aoss-response-hint: X01:network-policy-deny`** | AOSS is telling you the failure is due to **Serverless network policy** — who is allowed to talk to the collection **over the network** (e.g. VPC / VPC endpoints / public access rules). |
| **`content-length: 0`** | No JSON error body; common for this kind of policy denial. |

So: **traffic hits the OpenSearch Serverless endpoint**, but the **network policy** on the collection (or related AOSS networking) does **not** allow this request as it was sent (for example: instance in a VPC without the allowed endpoint / route, or public access disabled while you’re not on an allowed path, etc.).

**SigV4 / IAM** can still matter for **data access**, but the hint here is explicitly **network-policy-deny**, so fixing it is usually **AOSS network / VPC / endpoint / policy** alignment, not “wrong query JSON.”

**Practical next steps** (whoever owns the collection):

1. In the AWS console: **OpenSearch Serverless** → **Network policies** for that collection — confirm **VPC access**, **public** access, or **VPC endpoints** match how the EC2 instance reaches AWS (same VPC, private subnets, security groups, etc.).
2. Confirm the instance uses a path that policy allows (e.g. **interface VPC endpoint** for AOSS in the same VPC if policy is VPC-only).
3. After network policy is fixed, if you then see **403** with a **data access policy** message, that’s the separate **IAM / data access policy** layer.

**Bottom line:** You **are** getting to the **AOSS** service; you’re **not** allowed through to use the collection **with the current network setup** — which matches “someone changed the network settings.”

---

**User**

give me a simple curl command that I can use to verify connectivity

---

**Cursor**


Use plain **`curl`** to confirm **TLS + HTTP** reach the endpoint. You’ll usually get **401** without SigV4—that still means **connectivity is OK** (you reached AOSS).

```bash
curl -sS -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 10 \
  "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/"
```

A bit more detail (headers + status):

```bash
curl -sS -I --connect-timeout 10 \
  "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/"
```

**Note:** This does **not** prove **search** works or that **network/IAM policies** allow your use case—only that the host answers over HTTPS. For a real **`_search`** check you still need **SigV4** (e.g. **`awscurl`**) once policies allow it.

---

**User**

[ec2-user@ip-172-31-14-26 ~]$ curl -sS -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 10 \
  "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/"
HTTP 404
[ec2-user@ip-172-31-14-26 ~]$ curl -sS -I --connect-timeout 10 \
  "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/"
HTTP/1.1 404 Not Found
x-request-id: 2b6dadea-bd6b-9cab-951d-f5e16940a57c
date: Fri, 17 Apr 2026 21:51:38 GMT
server: aoss-amazon
transfer-encoding: chunked



---

**Cursor**


You **do** have connectivity.

A **404** on the **bare collection URL** (`https://…aoss.amazonaws.com/`) is normal for **OpenSearch Serverless**: there usually **isn’t** a useful resource at `/`, so the service answers **404 Not Found** instead of a cluster “info” page like some managed domains.

What matters for your sanity check:

- **TLS completed** (no timeout / connection refused).
- **HTTP response** came back with **`server: aoss-amazon`** — that’s the AOSS edge, not a generic TCP failure.

So this **`curl`** result **does not** contradict “can reach OpenSearch Serverless”; it only shows **“nothing lives at `/`.”**

When **network + IAM** allow it, an end-to-end check is a **signed** request to a real API path, e.g.:

```bash
awscurl --service aoss --region us-east-1 \
  -X POST "https://fyddewi9gmbuvxcee5nh.us-east-1.aoss.amazonaws.com/documents_text/_search" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"query":{"match_all":{}}}'
```

Unsigned **`curl`** to `…/documents_text/_search` will usually **not** prove access (you’ll get **401/403** without SigV4); your earlier **401 + `network-policy-deny`** was about **policy**, not “can’t connect.”

