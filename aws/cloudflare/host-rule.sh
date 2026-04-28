#!/usr/bin/env bash
# Manage a Cloudflare Transform Rule that rewrites the Host header on
# requests for $CLOUDFLARE_RECORD_NAME.$ZONE to the CloudFront origin
# domain.
#
# Why: Cloudflare's free proxy forwards the original Host header. CloudFront
# 403s any Host that doesn't match its own *.cloudfront.net domain or a
# configured Alias. Rewriting Host at Cloudflare's edge fixes this without
# needing an ACM cert + Alias on the AWS side.
#
# Idempotent: an existing rule with the same description is updated in
# place; otherwise a new rule is appended.

set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN in .env}"
: "${CLOUDFLARE_ZONE_ID:?Set CLOUDFLARE_ZONE_ID in .env}"
: "${CLOUDFLARE_RECORD_NAME:?Set CLOUDFLARE_RECORD_NAME in .env}"
: "${SAM_STACK_NAME:=netcidr}"
: "${AWS_REGION:=us-east-2}"

require() { command -v "$1" >/dev/null || { echo "Missing $1"; exit 1; }; }
require aws
require curl
require jq

RULE_DESCRIPTION="netcidr — rewrite Host to CloudFront origin"
PHASE="http_request_late_transform"
CF="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

# 1. Resolve the FQDN we want to match on.
ZONE_NAME=$(curl -fsS "${AUTH[@]}" "$CF/zones/$CLOUDFLARE_ZONE_ID" | jq -r '.result.name')
FQDN="${CLOUDFLARE_RECORD_NAME}.${ZONE_NAME}"

# 2. Pull the CloudFront domain from CFN.
CF_DOMAIN=$(aws cloudformation describe-stacks \
  --stack-name "$SAM_STACK_NAME" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomain`].OutputValue' \
  --output text)

if [[ -z "$CF_DOMAIN" || "$CF_DOMAIN" == "None" ]]; then
  echo "Could not read CloudFrontDomain from stack '$SAM_STACK_NAME'." >&2
  exit 1
fi

# 3. Find (or create) the entrypoint ruleset for the phase.
#    Cloudflare returns HTTP 404 (not a `success: false` body) when no
#    entrypoint exists yet, so we deliberately drop `-f` and check the
#    status code ourselves.
RULESET_RESPONSE=$(curl -sS -w '\n%{http_code}' "${AUTH[@]}" \
  "$CF/zones/$CLOUDFLARE_ZONE_ID/rulesets/phases/$PHASE/entrypoint")
RULESET_STATUS=$(tail -n1 <<<"$RULESET_RESPONSE")
RULESET=$(sed '$d' <<<"$RULESET_RESPONSE")

if [[ "$RULESET_STATUS" == "404" ]] || [[ "$(jq -r '.success' <<<"$RULESET" 2>/dev/null)" != "true" ]]; then
  echo "→ No entrypoint ruleset for phase $PHASE — creating it…"
  RULESET=$(curl -fsS -X POST "${AUTH[@]}" \
    "$CF/zones/$CLOUDFLARE_ZONE_ID/rulesets" \
    --data "$(jq -n --arg phase "$PHASE" \
      '{name: "default", kind: "zone", phase: $phase, rules: []}')")
fi

RULESET_ID=$(jq -r '.result.id' <<<"$RULESET")
if [[ -z "$RULESET_ID" || "$RULESET_ID" == "null" ]]; then
  echo "Failed to obtain a ruleset ID. Response was:" >&2
  echo "$RULESET" | jq . >&2 || echo "$RULESET" >&2
  exit 1
fi

# 4. Look for an existing rule with our description.
EXISTING_ID=$(jq -r --arg desc "$RULE_DESCRIPTION" \
  '.result.rules[]? | select(.description == $desc) | .id' \
  <<<"$RULESET" | head -n 1)

# 5. Build the rule body.
RULE_BODY=$(jq -n \
  --arg desc "$RULE_DESCRIPTION" \
  --arg expr "(http.host eq \"$FQDN\")" \
  --arg origin "$CF_DOMAIN" \
  '{
    description: $desc,
    expression: $expr,
    action: "rewrite",
    action_parameters: {
      headers: {
        "Host": { operation: "set", value: $origin }
      }
    },
    enabled: true
  }')

# 6. Upsert.
if [[ -n "$EXISTING_ID" ]]; then
  echo "→ Updating existing rule $EXISTING_ID — Host[$FQDN] := $CF_DOMAIN"
  curl -fsS -X PATCH "${AUTH[@]}" \
    "$CF/zones/$CLOUDFLARE_ZONE_ID/rulesets/$RULESET_ID/rules/$EXISTING_ID" \
    --data "$RULE_BODY" \
    | jq -e '.success' >/dev/null
else
  echo "→ Creating rule — Host[$FQDN] := $CF_DOMAIN"
  curl -fsS -X POST "${AUTH[@]}" \
    "$CF/zones/$CLOUDFLARE_ZONE_ID/rulesets/$RULESET_ID/rules" \
    --data "$RULE_BODY" \
    | jq -e '.success' >/dev/null
fi

echo "✓ Transform Rule applied. Test: curl -sS https://$FQDN/health"
