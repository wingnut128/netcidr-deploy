set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

region := "us-central1"
ar_repo := "netcidr-repo"
service := "netcidr"
notifier_name := "cloudbuild-slack-notifier"
slack_secret := "slack-webhook-cloudbuild"
cloudbuild_topic := "cloud-builds"
# Opt-in flag — see .env.example. Set NETCIDR_NOTIFIER=true in .env to enable.
notifier := env_var_or_default("NETCIDR_NOTIFIER", "false")
# gcloud config project (must be set via `gcloud config set project <id>`)
project := `gcloud config get-value project 2>/dev/null`

# List recipes
default:
    @just --list

# ─────────────────────────────── Bootstrap ───────────────────────────────

# One-time setup: APIs + AR repo + CB service-account perms (idempotent)
bootstrap:
    @test -n "{{project}}" || { echo "gcloud project not set. Run: gcloud config set project <id>"; exit 1; }
    @echo "Project: {{project}}   Notifier: {{notifier}}"

    @echo "→ Enabling core APIs…"
    @APIS="cloudbuild.googleapis.com artifactregistry.googleapis.com run.googleapis.com"; \
        if [ "{{notifier}}" = "true" ]; then \
            APIS="$APIS secretmanager.googleapis.com cloudfunctions.googleapis.com eventarc.googleapis.com pubsub.googleapis.com"; \
        fi; \
        gcloud services enable $APIS --project={{project}}

    @echo "→ Ensuring Artifact Registry repo…"
    @if gcloud artifacts repositories describe {{ar_repo}} --location={{region}} --project={{project}} >/dev/null 2>&1; then \
        echo "  AR repo '{{ar_repo}}' already exists — skipping."; \
    else \
        gcloud artifacts repositories create {{ar_repo}} \
            --repository-format=docker \
            --location={{region}} \
            --project={{project}}; \
    fi

    @if [ "{{notifier}}" = "true" ]; then \
        echo "→ Ensuring Cloud Build → Pub/Sub topic…"; \
        if gcloud pubsub topics describe {{cloudbuild_topic}} --project={{project}} >/dev/null 2>&1; then \
            echo "  Topic '{{cloudbuild_topic}}' already exists — skipping."; \
        else \
            gcloud pubsub topics create {{cloudbuild_topic}} --project={{project}}; \
        fi; \
    fi

    @echo "→ Granting run.admin to the Cloud Build service account…"
    @CB_SA="$(gcloud projects describe {{project}} --format='value(projectNumber)')-compute@developer.gserviceaccount.com"; \
        gcloud projects add-iam-policy-binding {{project}} \
            --member="serviceAccount:$CB_SA" \
            --role=roles/run.admin \
            --condition=None \
            --quiet >/dev/null; \
        echo "  run.admin granted to $CB_SA"

    @echo "✓ Bootstrap complete. Next: just deploy$(if [ "{{notifier}}" = "true" ]; then echo "  (or: just setup-slack)"; fi)"

# Store/rotate the Slack webhook in Secret Manager (prompts, never echoed)
setup-slack: _require-notifier
    @test -n "{{project}}" || { echo "gcloud project not set"; exit 1; }
    @echo -n "Paste Slack incoming webhook URL (hidden): "
    @read -rs WEBHOOK && echo && \
        if [ -z "$WEBHOOK" ]; then echo "Empty input; aborting."; exit 1; fi && \
        if gcloud secrets describe {{slack_secret}} --project={{project}} >/dev/null 2>&1; then \
            echo "→ Adding new version to existing secret '{{slack_secret}}'…"; \
            printf '%s' "$WEBHOOK" | gcloud secrets versions add {{slack_secret}} --data-file=- --project={{project}} >/dev/null; \
        else \
            echo "→ Creating secret '{{slack_secret}}'…"; \
            printf '%s' "$WEBHOOK" | gcloud secrets create {{slack_secret}} --data-file=- --project={{project}} >/dev/null; \
        fi && \
        unset WEBHOOK
    @echo "→ Granting secretAccessor to the compute SA…"
    @CB_SA="$(gcloud projects describe {{project}} --format='value(projectNumber)')-compute@developer.gserviceaccount.com"; \
        gcloud secrets add-iam-policy-binding {{slack_secret}} \
            --member="serviceAccount:$CB_SA" \
            --role=roles/secretmanager.secretAccessor \
            --project={{project}} --quiet >/dev/null
    @echo "✓ Slack secret stored. Next: just deploy-notifier"

# ──────────────────────────────── Deploy ────────────────────────────────

# Build + push + deploy (defaults from cloudbuild.yaml)
deploy:
    gcloud builds submit --config=cloudbuild.yaml --no-source --region={{region}}

# Deploy the latest upstream semver tag (resolved at build time)
deploy-latest:
    gcloud builds submit --config=cloudbuild.yaml --no-source --region={{region}} \
        --substitutions=_NETCIDR_REF=latest

# Deploy a specific upstream tag, branch, or commit SHA (e.g. `just deploy-ref v0.19.3`)
deploy-ref ref:
    gcloud builds submit --config=cloudbuild.yaml --no-source --region={{region}} \
        --substitutions=_NETCIDR_REF={{ref}}

# Deploy with custom Cargo features (e.g. `just deploy-features swagger false`)
deploy-features features with_dashboard="true":
    gcloud builds submit --config=cloudbuild.yaml --no-source --region={{region}} \
        --substitutions=_FEATURES={{features}},_WITH_DASHBOARD={{with_dashboard}}

# Deploy the Slack notifier Cloud Function (Pub/Sub trigger on cloud-builds topic)
deploy-notifier: _require-notifier
    @test -n "{{project}}" || { echo "gcloud project not set"; exit 1; }
    gcloud functions deploy {{notifier_name}} \
        --gen2 \
        --region={{region}} \
        --runtime=python312 \
        --source=./notifier \
        --entry-point=notify \
        --trigger-topic={{cloudbuild_topic}} \
        --set-env-vars=GCP_PROJECT={{project}},SLACK_SECRET_NAME={{slack_secret}},IMAGE_FILTER={{service}} \
        --project={{project}}

# ─────────────────────────────── Operate ────────────────────────────────

# Print the Cloud Run service URL
url:
    @gcloud run services describe {{service}} --region={{region}} --format='value(status.url)'

# Tail recent Cloud Run logs
logs:
    gcloud run services logs read {{service}} --region={{region}} --limit=50

# ─────────────────────────────── Teardown ───────────────────────────────

# Tear down the Cloud Run service (keeps AR images). Prompts for confirmation.
destroy:
    @if ! gcloud run services describe {{service}} --region={{region}} >/dev/null 2>&1; then \
        echo "Cloud Run service '{{service}}' not found — nothing to destroy."; \
        exit 0; \
    fi
    @read -p "Delete Cloud Run service '{{service}}' in {{region}}? [y/N] " ans; \
        [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
    gcloud run services delete {{service}} --region={{region}} --quiet

# Remove the Slack notifier Cloud Function
destroy-notifier: _require-notifier
    @if ! gcloud functions describe {{notifier_name}} --region={{region}} --project={{project}} >/dev/null 2>&1; then \
        echo "Function '{{notifier_name}}' not found — nothing to destroy."; \
        exit 0; \
    fi
    gcloud functions delete {{notifier_name}} --region={{region}} --quiet --project={{project}}

# ─────────────────────────────── Internal ───────────────────────────────

_require-notifier:
    @if [ "{{notifier}}" != "true" ]; then \
        echo "Slack notifier is disabled. Set NETCIDR_NOTIFIER=true in .env (see .env.example) and re-run 'just bootstrap' first."; \
        exit 1; \
    fi
