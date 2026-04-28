#!/usr/bin/env bash
# Provision an ACM certificate (in us-east-1, as CloudFront requires) for
# $CLOUDFLARE_RECORD_NAME.<zone>, auto-create the DNS validation CNAME in
# Cloudflare, and wait for ACM to mark it ISSUED. Idempotent — if a
# matching ISSUED cert already exists, prints its ARN and exits.
#
# After this prints the ARN, paste it into samconfig.toml.tpl under
# CertificateArn and run `just deploy`.

set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN in .env}"
: "${CLOUDFLARE_ZONE_ID:?Set CLOUDFLARE_ZONE_ID in .env}"
: "${CLOUDFLARE_RECORD_NAME:?Set CLOUDFLARE_RECORD_NAME in .env}"

require() { command -v "$1" >/dev/null || { echo "Missing $1"; exit 1; }; }
require aws
require curl
require jq

CF="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")
CERT_REGION=us-east-1   # CloudFront cert location is fixed.

ZONE_NAME=$(curl -fsS "${AUTH[@]}" "$CF/zones/$CLOUDFLARE_ZONE_ID" | jq -r '.result.name')
FQDN="${CLOUDFLARE_RECORD_NAME}.${ZONE_NAME}"

# 1. Reuse an already-issued cert if one exists.
EXISTING=$(aws acm list-certificates --region "$CERT_REGION" \
  --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='$FQDN'].CertificateArn" \
  --output text)

if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  ARN=$(awk '{print $1}' <<<"$EXISTING")
  echo "[OK] Existing ISSUED cert for $FQDN:"
  echo "    $ARN"
  echo "Paste that into samconfig.toml.tpl as CertificateArn."
  exit 0
fi

# 2. Request a new cert.
echo "-> Requesting ACM cert for $FQDN in $CERT_REGION"
if ! ARN=$(aws acm request-certificate --region "$CERT_REGION" \
  --domain-name "$FQDN" \
  --validation-method DNS \
  --query CertificateArn --output text 2>&1); then
  echo "[FAIL] aws acm request-certificate failed:" >&2
  echo "$ARN" >&2
  exit 1
fi

if [[ -z "$ARN" || "$ARN" == "None" || "$ARN" != arn:aws:acm:* ]]; then
  echo "[FAIL] Did not receive a valid ARN from request-certificate." >&2
  echo "  Got: '$ARN'" >&2
  exit 1
fi
echo "  $ARN"

# 3. Poll for ACM to surface the validation record.
echo "-> Waiting for ACM to surface the validation record..."
for attempt in $(seq 1 30); do
  if ! RECORD=$(aws acm describe-certificate --region "$CERT_REGION" \
        --certificate-arn "$ARN" \
        --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
        --output json 2>&1); then
    echo "[FAIL] describe-certificate failed (attempt $attempt):" >&2
    echo "$RECORD" >&2
    exit 1
  fi
  if [[ "$(jq -r '.Name // empty' <<<"$RECORD" 2>/dev/null)" != "" ]]; then
    break
  fi
  sleep 2
done

VAL_NAME=$(jq -r '.Name // empty'  <<<"$RECORD" 2>/dev/null)
VAL_VALUE=$(jq -r '.Value // empty' <<<"$RECORD" 2>/dev/null)
VAL_NAME=${VAL_NAME%.}      # strip trailing dot
VAL_VALUE=${VAL_VALUE%.}

if [[ -z "$VAL_NAME" || -z "$VAL_VALUE" ]]; then
  echo "[FAIL] ACM never surfaced a validation record after 60s. Last response:" >&2
  echo "$RECORD" | jq . >&2 || echo "$RECORD" >&2
  echo "" >&2
  echo "The cert ($ARN) was created but is unvalidated. You can:" >&2
  echo "  1. Re-run this script (it will reuse the cert and try again)" >&2
  echo "  2. Or describe it manually:" >&2
  echo "     aws acm describe-certificate --region $CERT_REGION --certificate-arn $ARN" >&2
  exit 1
fi

echo "-> Creating Cloudflare CNAME for validation:"
echo "    $VAL_NAME -> $VAL_VALUE"

# 4. Upsert the validation CNAME (gray cloud — must be DNS-only for ACM).
PAYLOAD=$(jq -n \
  --arg name "$VAL_NAME" \
  --arg content "$VAL_VALUE" \
  '{type: "CNAME", name: $name, content: $content, ttl: 60, proxied: false, comment: "ACM cert validation for netcidr (auto-managed)"}')

EXISTING_ID=$(curl -fsS "${AUTH[@]}" \
  "$CF/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=CNAME&name=$VAL_NAME" \
  | jq -r '.result[0].id // empty')

if [[ -n "$EXISTING_ID" ]]; then
  curl -fsS -X PUT "${AUTH[@]}" \
    "$CF/zones/$CLOUDFLARE_ZONE_ID/dns_records/$EXISTING_ID" \
    --data "$PAYLOAD" | jq -e '.success' >/dev/null
else
  curl -fsS -X POST "${AUTH[@]}" \
    "$CF/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
    --data "$PAYLOAD" | jq -e '.success' >/dev/null
fi

# 5. Wait for ACM to validate.
echo "-> Waiting for ACM to validate (typically <2 min)..."
aws acm wait certificate-validated --region "$CERT_REGION" --certificate-arn "$ARN"
echo "[OK] Cert ISSUED."
echo ""
echo "Paste this ARN into samconfig.toml.tpl under CertificateArn:"
echo "    $ARN"
