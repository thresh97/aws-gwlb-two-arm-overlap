#!/usr/bin/env bash
# =============================================================================
# scm_commit_test.sh — test SCM commit endpoint interactively
#
# Reads credentials from terraform.tfvars (gitignored) and tests the SCM
# commit API with full verbose output so the correct endpoint can be found.
#
# Usage:
#   chmod +x scm_commit_test.sh
#   ./scm_commit_test.sh
# =============================================================================

set -euo pipefail

TFVARS="terraform.tfvars"

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: $TFVARS not found. Run from the repo root." >&2
  exit 1
fi

read_var() {
  grep -E "^\s*$1\s*=" "$TFVARS" | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/'
}

CLIENT_ID=$(read_var scm_client_id)
CLIENT_SECRET=$(read_var scm_client_secret)
SCOPE=$(read_var scm_scope)
FOLDER=$(read_var dgname)

echo "=== SCM Commit Endpoint Test ==="
echo "Folder: $FOLDER"
echo "Scope:  $SCOPE"
echo ""

# ---------------------------------------------------------------------------
# Get token
# ---------------------------------------------------------------------------
echo "--- Getting OAuth2 token ---"
TOKEN_RESPONSE=$(curl -s -X POST \
  "https://auth.apps.paloaltonetworks.com/auth/v1/oauth2/access_token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "scope=$SCOPE")

TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Failed to get token. Response:"
  echo "$TOKEN_RESPONSE" | jq .
  exit 1
fi
echo "Token obtained OK"
echo ""

# ---------------------------------------------------------------------------
# Try candidate commit endpoints
# ---------------------------------------------------------------------------
BODY="{\"folders\":[\"$FOLDER\"],\"description\":\"Terraform apply - test\"}"

try_endpoint() {
  local URL="$1"
  echo "--- Trying: $URL ---"
  curl -sv -X POST "$URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>&1
  echo ""
}

try_endpoint "https://api.sase.paloaltonetworks.com/sse/config/v1/config-versions/candidate:commit"
try_endpoint "https://api.sase.paloaltonetworks.com/config/v1/config-versions/candidate:commit"
try_endpoint "https://api.sase.paloaltonetworks.com/sse/config/v1/candidate:commit"
try_endpoint "https://api.sase.paloaltonetworks.com/sse/config/v1/config-versions/running:candidate"
