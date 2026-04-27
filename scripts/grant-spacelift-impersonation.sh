#!/usr/bin/env bash
# Grant the Spacelift-managed GCP service account permission to impersonate
# the spacelift-deployer SA in this project.
#
# Use this when you've configured Spacelift's OAuth-flavored GCP integration
# (the one that shows you a `gcp-XXXX@<region>-spacelift.iam.gserviceaccount.com`
# service account email). Spacelift mints OAuth tokens for that SA; this
# binding lets the SA assume `spacelift-deployer` so your Terraform runs as
# the SA you control rather than Spacelift's.
#
# After running, set this env var on the Spacelift stack:
#
#   GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=spacelift-deployer@<project>.iam.gserviceaccount.com
#
# The Google Terraform provider reads that natively and does the
# impersonation hop on every API call.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-tasker-487819}"
DEPLOYER_SA="${DEPLOYER_SA:-spacelift-deployer@${PROJECT_ID}.iam.gserviceaccount.com}"

# The Spacelift-managed SA email shown in your Spacelift GCP integration UI.
# Format: gcp-XXXX@<region>-spacelift.iam.gserviceaccount.com
SPACELIFT_GCP_SA="${SPACELIFT_GCP_SA:-REPLACE-ME}"

if [[ "$SPACELIFT_GCP_SA" == "REPLACE-ME" ]]; then
  echo "ERROR: set SPACELIFT_GCP_SA before running." >&2
  echo "       Find it in Spacelift → Settings → Cloud integrations →" >&2
  echo "       <your GCP integration> → Service account." >&2
  exit 1
fi

# Shape check: must look like an email ending in
# -spacelift.iam.gserviceaccount.com. Also catches the most common
# copy/paste mistake — pasting a literal Unicode ellipsis (…) from chat
# rather than the full SA email — because non-ASCII chars don't match the
# allowed local-part character class.
if [[ ! "$SPACELIFT_GCP_SA" =~ ^[A-Za-z0-9._-]+@[a-z0-9-]+-spacelift\.iam\.gserviceaccount\.com$ ]]; then
  echo "ERROR: SPACELIFT_GCP_SA does not look like a Spacelift-managed SA email." >&2
  echo "       Expected format: gcp-XXXX@<region>-spacelift.iam.gserviceaccount.com" >&2
  echo "       Got:             $SPACELIFT_GCP_SA" >&2
  echo "       Tip: copy the full email from Spacelift; don't abbreviate" >&2
  echo "            with '…' or '...'." >&2
  exit 1
fi

echo "Project:                       $PROJECT_ID"
echo "Deployer SA (impersonated):    $DEPLOYER_SA"
echo "Spacelift SA (impersonating):  $SPACELIFT_GCP_SA"
echo

gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="serviceAccount:${SPACELIFT_GCP_SA}" \
  --condition=None

cat <<EOF

──────────────────────────────────────────────────────────────────────────
✅ Done. Now in Spacelift → Stack → Environment, add:

  GOOGLE_IMPERSONATE_SERVICE_ACCOUNT = ${DEPLOYER_SA}

(plain variable, not secret — it's just an SA email).

Trigger a run; the Google Terraform provider will exchange Spacelift's
OAuth token for an impersonated token on ${DEPLOYER_SA} for every
API call.
──────────────────────────────────────────────────────────────────────────
EOF
