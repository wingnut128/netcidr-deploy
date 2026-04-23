set shell := ["bash", "-euo", "pipefail", "-c"]

region := "us-central1"
ar_repo := "netcidr-repo"
service := "netcidr"
# gcloud config project (must be set via `gcloud config set project <id>`)
project := `gcloud config get-value project 2>/dev/null`

# List recipes
default:
    @just --list

# One-time setup: AR repo + required API enablement + Cloud Build SA perms (idempotent)
bootstrap:
    @test -n "{{project}}" || { echo "gcloud project not set. Run: gcloud config set project <id>"; exit 1; }
    @echo "Project: {{project}}"

    @echo "→ Enabling required APIs…"
    gcloud services enable \
        cloudbuild.googleapis.com \
        artifactregistry.googleapis.com \
        run.googleapis.com \
        --project={{project}}

    @echo "→ Ensuring Artifact Registry repo…"
    @if gcloud artifacts repositories describe {{ar_repo}} --location={{region}} --project={{project}} >/dev/null 2>&1; then \
        echo "  AR repo '{{ar_repo}}' already exists in {{region}} — skipping."; \
    else \
        gcloud artifacts repositories create {{ar_repo}} \
            --repository-format=docker \
            --location={{region}} \
            --project={{project}}; \
    fi

    @echo "→ Granting run.admin to the Cloud Build service account (so --allow-unauthenticated sticks)…"
    @PROJECT_NUMBER=$(gcloud projects describe {{project}} --format='value(projectNumber)'); \
        CB_SA="$${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"; \
        gcloud projects add-iam-policy-binding {{project}} \
            --member="serviceAccount:$${CB_SA}" \
            --role=roles/run.admin \
            --condition=None \
            --quiet >/dev/null; \
        echo "  run.admin granted to $${CB_SA}"

    @echo "✓ Bootstrap complete. You can now run: just deploy"

# Build + push + deploy (defaults from cloudbuild.yaml)
deploy:
    gcloud builds submit --config=cloudbuild.yaml --no-source

# Deploy the latest upstream semver tag (resolved at build time)
deploy-latest:
    gcloud builds submit --config=cloudbuild.yaml --no-source \
        --substitutions=_NETCIDR_REF=latest

# Deploy a specific upstream tag, branch, or commit SHA (e.g. `just deploy-ref v0.19.3`)
deploy-ref ref:
    gcloud builds submit --config=cloudbuild.yaml --no-source \
        --substitutions=_NETCIDR_REF={{ref}}

# Deploy with custom Cargo features (e.g. `just deploy-features swagger false`)
deploy-features features with_dashboard="true":
    gcloud builds submit --config=cloudbuild.yaml --no-source \
        --substitutions=_FEATURES={{features}},_WITH_DASHBOARD={{with_dashboard}}

# Print the service URL
url:
    @gcloud run services describe {{service}} --region={{region}} --format='value(status.url)'

# Tail recent Cloud Run logs
logs:
    gcloud run services logs read {{service}} --region={{region}} --limit=50

# Tear down the Cloud Run service (keeps AR images). Prompts for confirmation.
destroy:
    @if ! gcloud run services describe {{service}} --region={{region}} >/dev/null 2>&1; then \
        echo "Cloud Run service '{{service}}' not found in {{region}} — nothing to destroy."; \
        exit 0; \
    fi
    @read -p "Delete Cloud Run service '{{service}}' in {{region}}? [y/N] " ans; \
        [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
    gcloud run services delete {{service}} --region={{region}} --quiet
