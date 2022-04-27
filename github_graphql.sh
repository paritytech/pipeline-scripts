#!/usr/bin/env bash

ghgql_latest_repositories_refs_query() {
  unset out

  local org="$1"
  local repo="$2"
  local refs_query="$3"

  echo "
    query { 
      repository(owner: \"$org\", name: \"$repo\") {
        refs(
          refPrefix: \"refs/heads/\",
          first: 32,
          query: \"$refs_query\",
          orderBy: { field: TAG_COMMIT_DATE, direction: DESC }
        ) {
          edges {
            node {
              name
            }
          }
        }
      }
    }
  "
}

ghgql_post() {
  local github_graphql_api="$1"
  local github_api_token="$2"
  local query="$3"

  local req_body
  req_body="{ \"query\": \"$(echo "$query" | tr -d '\n' | sed 's/"/\\"/g')\" }"

  >&2 echo "
Sending GraphQL body to $github_graphql_api
Raw query: $query
Request body: $req_body
"

  curl \
    -sSL \
    -H "Content-Type: application/json" \
    -H "Authorization: bearer $github_api_token" \
    -X POST \
    -d "$req_body" \
    "$github_graphql_api"
}
