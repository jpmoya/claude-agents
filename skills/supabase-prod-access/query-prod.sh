#!/usr/bin/env bash
# Read-only query against scheduler's PRODUCTION Supabase project via the
# Management API, using the PAT stored in macOS Keychain. Never echoes the
# token. See SKILL.md in this folder for details and the migration-ledger
# recording flow (not covered by this script).
#
# Usage: ./query-prod.sh "select count(*) from public.visits;"
set -euo pipefail

PROD_REF="ywwnprpncqrqfiskmoot"  # scheduler production — hardcoded, never derive from env vars

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 \"<sql query>\"" >&2
  exit 2
fi

SQL="$1"

PAT=$(security find-generic-password -s "supabase-pat" -w 2>/dev/null) || {
  echo "Could not find Keychain item 'supabase-pat' (account 'supabase')." >&2
  echo "Fallback: sign in to Supabase Studio in a browser with JP's saved credential." >&2
  exit 1
}

# Build the JSON body without ever putting $PAT into anything but the header.
BODY=$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$SQL")

curl -s "https://api.supabase.com/v1/projects/${PROD_REF}/database/query" \
  -H "Authorization: Bearer ${PAT}" \
  -H "Content-Type: application/json" \
  -d "${BODY}"
echo
