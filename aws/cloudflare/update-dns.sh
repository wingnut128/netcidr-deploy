#!/usr/bin/env bash
# Sync a Cloudflare CNAME to the current Lambda Function URL.
#
# Reads the URL from the netcidr CloudFormation stack output, strips the
# scheme and trailing slash, then upserts a CNAME at
# $CLOUDFLARE_RECORD_NAME → <function-url-host>.
#
# Idempotent: existing record is updated in place, missing record is
# created. Cloudflare's orange-cloud proxy is toggled per
# $CLOUDFLARE_PROXIED.

set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN in .env}"
: "${CLOUDFLARE_ZONE_ID:?Set CLOUDFLARE_ZONE_ID in .env}"
: "${CLOUDFLARE_RECORD_NAME:?Set CLOUDFLARE_RECORD_NAME in .env}"
: "${SAM_STACK_NAME:=netcidr}"
: "${AWS_REGION:=us-east-1}"
: "${CLOUDFLARE_PROXIED:=true}"

require() { command -v "$1" >/dev/null || { echo "Missing $1"; exit 1; }; }
require aws
require curl
require jq

# 1. Pull the Function URL from the CFN stack output.
FN_URL=$(aws cloudformation describe-stacks \
  --stack-name "$SAM_STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`FunctionUrl`].OutputValue' \
  --output text)

if [[ -z "$FN_URL" || "$FN_URL" == "None" ]]; then
  echo "Could not read FunctionUrl from stack '$SAM_STACK_NAME' in $AWS_REGION." >&2
  echo "Has 'just deploy' been run?" >&2
  exit 1
fi

TARGET_HOST=$(echo "$FN_URL" | sed -E 's|^https?://||; s|/$||')

# 2. Resolve the zone's apex name so we can build the FQDN for matching.
ZONE_NAME=$(curl -fsS \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID" \
  | jq -r '.result.name')

FQDN="${CLOUDFLARE_RECORD_NAME}.${ZONE_NAME}"

# 3. Look up an existing CNAME at $FQDN.
EXISTING=$(curl -fsS \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=CNAME&name=$FQDN" \
  | jq -r '.result[0].id // empty')

PAYLOAD=$(jq -n \
  --arg name "$CLOUDFLARE_RECORD_NAME" \
  --arg content "$TARGET_HOST" \
  --argjson proxied "$CLOUDFLARE_PROXIED" \
  '{type: "CNAME", name: $name, content: $content, ttl: 1, proxied: $proxied, comment: "Managed by netcidr-deploy/aws/cloudflare/update-dns.sh"}')

if [[ -n "$EXISTING" ]]; then
  echo "→ Updating $FQDN → $TARGET_HOST (proxied=$CLOUDFLARE_PROXIED)"
  curl -fsS -X PUT \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records/$EXISTING" \
    --data "$PAYLOAD" \
    | jq -e '.success' >/dev/null
else
  echo "→ Creating $FQDN → $TARGET_HOST (proxied=$CLOUDFLARE_PROXIED)"
  curl -fsS -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
    --data "$PAYLOAD" \
    | jq -e '.success' >/dev/null
fi

echo "✓ $FQDN now resolves to $TARGET_HOST"
