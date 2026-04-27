#!/usr/bin/env bash
# Create the Workload Identity Pool, OIDC provider, and impersonatable
# service account that Spacelift uses to run Terraform against this GCP
# project.
#
# Run this once per project. Idempotent-ish: re-running with the same names
# will fail on existing resources rather than overwrite them — that's
# intentional, edit by hand if you need to change something.
#
# Prereqs:
#   - gcloud CLI authenticated as a user with project owner/editor.
#   - The Spacelift account name (the slug in your Spacelift URL —
#     https://<account>.app.spacelift.io).
#   - The GCP project ID.
#
# After running, copy the printed values into the Spacelift "GCP cloud
# integration" form (Settings → Cloud integrations → GCP → Add).

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-tasker-487819}"

# The slug in your Spacelift hostname (everything before `.app.`).
# Example: hostname `drevil.app.us.spacelift.io` → SPACELIFT_ACCOUNT=drevil
SPACELIFT_ACCOUNT="${SPACELIFT_ACCOUNT:-REPLACE-ME}"
# The region segment of the hostname: `us`, `eu`, or empty for `app.spacelift.io`.
# Example: `drevil.app.us.spacelift.io` → SPACELIFT_REGION=us
SPACELIFT_REGION="${SPACELIFT_REGION:-us}"

POOL_ID="${POOL_ID:-spacelift-pool}"
POOL_DISPLAY="${POOL_DISPLAY:-Spacelift OIDC pool}"
PROVIDER_ID="${PROVIDER_ID:-spacelift-oidc}"
PROVIDER_DISPLAY="${PROVIDER_DISPLAY:-Spacelift OIDC provider}"

SA_NAME="${SA_NAME:-spacelift-deployer}"
SA_DISPLAY="${SA_DISPLAY:-Spacelift Terraform deployer}"

# Spacelift OIDC token claims (per
# https://docs.spacelift.io/integrations/cloud-providers/oidc/gcp-oidc):
#   iss = https://<account>.app[.<region>].spacelift.io   (the hostname URL)
#   aud = <account>.app[.<region>].spacelift.io           (the hostname,
#                                                          no scheme)
if [[ -n "$SPACELIFT_REGION" ]]; then
  HOSTNAME_DEFAULT="${SPACELIFT_ACCOUNT}.app.${SPACELIFT_REGION}.spacelift.io"
else
  HOSTNAME_DEFAULT="${SPACELIFT_ACCOUNT}.app.spacelift.io"
fi
ISSUER_URI="${ISSUER_URI:-https://${HOSTNAME_DEFAULT}}"
ALLOWED_AUDIENCE="${ALLOWED_AUDIENCE:-${HOSTNAME_DEFAULT}}"

# Project roles granted to the deployer SA. Mirrors what the
# `terraform/v2` stack needs to create. Adjust if you tighten the stack.
ROLES=(
  "roles/run.admin"
  "roles/iam.serviceAccountAdmin"
  "roles/iam.serviceAccountUser"
  "roles/cloudsql.admin"
  "roles/secretmanager.admin"
  "roles/artifactregistry.admin"
  "roles/cloudbuild.builds.editor"
  "roles/compute.networkAdmin"
  "roles/servicenetworking.networksAdmin"
  "roles/serviceusage.serviceUsageAdmin"
  "roles/resourcemanager.projectIamAdmin"
)

# ── Pre-flight ──────────────────────────────────────────────────────────
if [[ "$SPACELIFT_ACCOUNT" == "REPLACE-ME" ]]; then
  echo "ERROR: set SPACELIFT_ACCOUNT before running (the slug in your Spacelift URL)" >&2
  exit 1
fi

echo "Using project:           $PROJECT_ID"
echo "Spacelift account:       $SPACELIFT_ACCOUNT"
echo "Issuer URI:              $ISSUER_URI"
echo "Allowed audience:        $ALLOWED_AUDIENCE"
echo "Workload Identity Pool:  $POOL_ID"
echo "OIDC provider:           $PROVIDER_ID"
echo "Service account:         $SA_NAME"
echo

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ── 1. Required APIs ────────────────────────────────────────────────────
echo "==> Enabling required APIs"
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"

# ── 2. Service account ──────────────────────────────────────────────────
echo "==> Creating service account ${SA_EMAIL}"
gcloud iam service-accounts create "$SA_NAME" \
  --project="$PROJECT_ID" \
  --display-name="$SA_DISPLAY" \
  --description="Impersonated by Spacelift via Workload Identity Federation to run Terraform."

# ── 3. Grant project roles ──────────────────────────────────────────────
echo "==> Granting project roles to ${SA_EMAIL}"
for ROLE in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$ROLE" \
    --condition=None \
    --quiet >/dev/null
  echo "    granted $ROLE"
done

# ── 4. Workload Identity Pool ───────────────────────────────────────────
echo "==> Creating Workload Identity Pool ${POOL_ID}"
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" \
  --location=global \
  --display-name="$POOL_DISPLAY" \
  --description="Federated identity pool for Spacelift OIDC tokens."

# ── 5. OIDC provider in the pool ────────────────────────────────────────
# Attribute mapping pulls Spacelift claims into Google attributes so we can
# bind impersonation to a specific account / stack later.
echo "==> Creating OIDC provider ${PROVIDER_ID}"
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location=global \
  --workload-identity-pool="$POOL_ID" \
  --display-name="$PROVIDER_DISPLAY" \
  --issuer-uri="$ISSUER_URI" \
  --allowed-audiences="$ALLOWED_AUDIENCE" \
  --attribute-mapping="\
google.subject=assertion.sub,\
attribute.aud=assertion.aud,\
attribute.space=assertion.spaceId,\
attribute.stack=assertion.stackId,\
attribute.run_type=assertion.runType,\
attribute.scope=assertion.scope"

# ── 6. Allow Spacelift identities to impersonate the deployer SA ────────
# Lock impersonation to tokens whose `aud` claim equals our allowed
# audience. Tighten further later by switching to attribute.stack when you
# know the stack IDs.
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
PRINCIPAL="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.aud/${ALLOWED_AUDIENCE}"

echo "==> Binding workloadIdentityUser on ${SA_EMAIL}"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$PRINCIPAL" \
  --condition=None

# ── 7. Output the values Spacelift needs ────────────────────────────────
PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${PROVIDER_ID}"

cat <<EOF

──────────────────────────────────────────────────────────────────────────
✅ Done. Paste these into the Spacelift GCP cloud integration form:

  Service account email:
    ${SA_EMAIL}

  Workload Identity Provider (full resource path):
    ${PROVIDER_RESOURCE}

  GCP project ID:                    ${PROJECT_ID}
  GCP project number:                ${PROJECT_NUMBER}
  Audience Spacelift will use:       ${ALLOWED_AUDIENCE}

To tighten later (recommended once your Spacelift stacks are stable),
replace the broad attribute.aud binding with one that pins a specific
stack:

  gcloud iam service-accounts remove-iam-policy-binding ${SA_EMAIL} \\
    --project=${PROJECT_ID} \\
    --role=roles/iam.workloadIdentityUser \\
    --member=${PRINCIPAL}

  gcloud iam service-accounts add-iam-policy-binding ${SA_EMAIL} \\
    --project=${PROJECT_ID} \\
    --role=roles/iam.workloadIdentityUser \\
    --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.stack/<STACK_ID>"
──────────────────────────────────────────────────────────────────────────
EOF
