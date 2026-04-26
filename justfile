set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

region := "us-central1"
ar_repo := "netcidr-repo"
service := "netcidr"
v2_service := "netcidr-v2"
v2_image := "netcidr-v2"
v2_ref := "v2"
notifier_name := "cloudbuild-slack-notifier"
slack_secret := "slack-webhook-cloudbuild"
cloudbuild_topic := "cloud-builds"
cb_connection := "github-connection"
cb_repo := "netcidr-deploy"
autobuild_trigger := "netcidr-weekly-rebuild"
v2_trigger := "netcidr-v2-manual"
autobuild_schedule := "0 9 * * 1"
autobuild_tz := "America/New_York"
# Opt-in flags — see .env.example. Set in .env to enable.
notifier := env_var_or_default("NETCIDR_NOTIFIER", "false")
autobuild := env_var_or_default("NETCIDR_AUTOBUILD", "false")
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
        if [ "{{autobuild}}" = "true" ]; then \
            APIS="$APIS cloudscheduler.googleapis.com"; \
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

    @if [ "{{autobuild}}" = "true" ]; then \
        echo "→ Granting cloudbuild.builds.editor to compute SA (for trigger runs)…"; \
        CB_SA="$(gcloud projects describe {{project}} --format='value(projectNumber)')-compute@developer.gserviceaccount.com"; \
        gcloud projects add-iam-policy-binding {{project}} \
            --member="serviceAccount:$CB_SA" \
            --role=roles/cloudbuild.builds.editor \
            --condition=None --quiet >/dev/null; \
        echo "  cloudbuild.builds.editor granted"; \
    fi

    @echo "✓ Bootstrap complete. Next: just deploy"

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

# Build + push + deploy the upstream netcidr v2 branch to a separate Cloud Run service
deploy-v2:
    gcloud builds submit --config=cloudbuild.yaml --no-source --region={{region}} \
        --substitutions=_NETCIDR_REF={{v2_ref}},_IMAGE_NAME={{v2_image}},_SERVICE_NAME={{v2_service}}

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

# Map a custom domain to the Cloud Run service (prereq: verified in Search Console)
map-domain hostname:
    @test -n "{{project}}" || { echo "gcloud project not set"; exit 1; }
    gcloud beta run domain-mappings create \
        --service={{service}} \
        --domain={{hostname}} \
        --region={{region}} \
        --project={{project}}
    @echo ""
    @echo "DNS records required:"
    gcloud beta run domain-mappings describe \
        --domain={{hostname}} \
        --region={{region}} \
        --project={{project}} \
        --format='table(status.resourceRecords[].name, status.resourceRecords[].type, status.resourceRecords[].rrdata)'
    @echo ""
    @echo "Certificate provisioning takes ~15-60 min after DNS propagates."

# Remove a custom domain mapping
unmap-domain hostname:
    gcloud beta run domain-mappings delete \
        --domain={{hostname}} \
        --region={{region}} \
        --project={{project}} \
        --quiet

# Show status of a domain mapping (cert provisioning, DNS validation)
domain-status hostname:
    @gcloud beta run domain-mappings describe \
        --domain={{hostname}} \
        --region={{region}} \
        --project={{project}} \
        --format='yaml(status.conditions, status.resourceRecords, status.mappedRouteName)'

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

# ─────────────────────────────── Autobuild ──────────────────────────────

# Wire a manual Cloud Build trigger for the upstream netcidr v2 branch (idempotent)
setup-v2-trigger:
    @test -n "{{project}}" || { echo "gcloud project not set. Run: gcloud config set project <id>"; exit 1; }
    @echo "→ Checking Cloud Build GitHub repo link…"
    @if ! gcloud builds repositories describe {{cb_repo}} --connection={{cb_connection}} --region={{region}} --project={{project}} >/dev/null 2>&1; then \
        echo "  Linking repo {{cb_repo}} to connection {{cb_connection}}…"; \
        gcloud builds repositories create {{cb_repo}} \
            --remote-uri=https://github.com/wingnut128/{{cb_repo}}.git \
            --connection={{cb_connection}} \
            --region={{region}} \
            --project={{project}}; \
    else \
        echo "  Repo already linked — skipping."; \
    fi

    @echo "→ Ensuring Cloud Build manual v2 trigger…"
    @PROJECT_NUM=$(gcloud projects describe {{project}} --format='value(projectNumber)'); \
        CB_SA="$PROJECT_NUM-compute@developer.gserviceaccount.com"; \
        REPO="projects/{{project}}/locations/{{region}}/connections/{{cb_connection}}/repositories/{{cb_repo}}"; \
        gcloud projects add-iam-policy-binding {{project}} \
            --member="serviceAccount:$CB_SA" \
            --role=roles/cloudbuild.builds.editor \
            --condition=None --quiet >/dev/null; \
        EXISTING=$(gcloud builds triggers list --region={{region}} --project={{project}} --filter="name:{{v2_trigger}}" --format='value(name)' 2>/dev/null); \
        if [ -n "$EXISTING" ]; then \
            echo "  Trigger '{{v2_trigger}}' already exists — skipping."; \
        else \
            curl -sX POST \
                "https://cloudbuild.googleapis.com/v1/projects/{{project}}/locations/{{region}}/triggers" \
                -H "Authorization: Bearer $(gcloud auth print-access-token)" \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"{{v2_trigger}}\",\"description\":\"Manual build and deploy of upstream netcidr v2 branch\",\"sourceToBuild\":{\"repository\":\"$REPO\",\"ref\":\"refs/heads/main\",\"repoType\":\"GITHUB\"},\"gitFileSource\":{\"path\":\"cloudbuild.yaml\",\"repository\":\"$REPO\",\"revision\":\"refs/heads/main\",\"repoType\":\"GITHUB\"},\"substitutions\":{\"_NETCIDR_REF\":\"{{v2_ref}}\",\"_IMAGE_NAME\":\"{{v2_image}}\",\"_SERVICE_NAME\":\"{{v2_service}}\"},\"serviceAccount\":\"projects/{{project}}/serviceAccounts/$CB_SA\"}" \
                | grep -q '"name"' && echo "  Trigger created." || { echo "  Trigger creation failed."; exit 1; }; \
        fi
    @echo "✓ Manual v2 trigger wired. Run it with: just fire-v2-trigger"

# Fire the manual v2 Cloud Build trigger
fire-v2-trigger:
    @gcloud builds triggers run {{v2_trigger}} --region={{region}} --branch=main --project={{project}}
    @echo "✓ v2 build triggered. Tail progress: just logs-build"

# Remove the manual v2 Cloud Build trigger
destroy-v2-trigger:
    @gcloud builds triggers delete {{v2_trigger}} --region={{region}} --project={{project}} --quiet 2>&1 | tail -2 || true

# Wire the weekly auto-rebuild: CB trigger + Cloud Scheduler job (idempotent)
setup-autobuild: _require-autobuild
    @test -n "{{project}}" || { echo "gcloud project not set"; exit 1; }
    @echo "→ Checking Cloud Build GitHub repo link…"
    @if ! gcloud builds repositories describe {{cb_repo}} --connection={{cb_connection}} --region={{region}} --project={{project}} >/dev/null 2>&1; then \
        echo "  Linking repo {{cb_repo}} to connection {{cb_connection}}…"; \
        gcloud builds repositories create {{cb_repo}} \
            --remote-uri=https://github.com/wingnut128/{{cb_repo}}.git \
            --connection={{cb_connection}} \
            --region={{region}} \
            --project={{project}}; \
    else \
        echo "  Repo already linked — skipping."; \
    fi

    @echo "→ Ensuring Cloud Build manual trigger…"
    @PROJECT_NUM=$(gcloud projects describe {{project}} --format='value(projectNumber)'); \
        CB_SA="$PROJECT_NUM-compute@developer.gserviceaccount.com"; \
        REPO="projects/{{project}}/locations/{{region}}/connections/{{cb_connection}}/repositories/{{cb_repo}}"; \
        EXISTING=$(gcloud builds triggers list --region={{region}} --project={{project}} --filter="name:{{autobuild_trigger}}" --format='value(name)' 2>/dev/null); \
        if [ -n "$EXISTING" ]; then \
            echo "  Trigger '{{autobuild_trigger}}' already exists — skipping."; \
        else \
            curl -sX POST \
                "https://cloudbuild.googleapis.com/v1/projects/{{project}}/locations/{{region}}/triggers" \
                -H "Authorization: Bearer $(gcloud auth print-access-token)" \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"{{autobuild_trigger}}\",\"description\":\"Scheduled rebuild from latest netcidr release\",\"sourceToBuild\":{\"repository\":\"$REPO\",\"ref\":\"refs/heads/main\",\"repoType\":\"GITHUB\"},\"gitFileSource\":{\"path\":\"cloudbuild.yaml\",\"repository\":\"$REPO\",\"revision\":\"refs/heads/main\",\"repoType\":\"GITHUB\"},\"substitutions\":{\"_NETCIDR_REF\":\"latest\"},\"serviceAccount\":\"projects/{{project}}/serviceAccounts/$CB_SA\"}" \
                | grep -q '"name"' && echo "  Trigger created." || { echo "  Trigger creation failed."; exit 1; }; \
        fi

    @echo "→ Ensuring Cloud Scheduler job ({{autobuild_schedule}} {{autobuild_tz}})…"
    @CB_SA="$(gcloud projects describe {{project}} --format='value(projectNumber)')-compute@developer.gserviceaccount.com"; \
        if gcloud scheduler jobs describe {{autobuild_trigger}} --location={{region}} --project={{project}} >/dev/null 2>&1; then \
            echo "  Scheduler job already exists — skipping."; \
        else \
            gcloud scheduler jobs create http {{autobuild_trigger}} \
                --location={{region}} \
                --schedule="{{autobuild_schedule}}" \
                --time-zone="{{autobuild_tz}}" \
                --uri="https://cloudbuild.googleapis.com/v1/projects/{{project}}/locations/{{region}}/triggers/{{autobuild_trigger}}:run" \
                --http-method=POST \
                --update-headers=Content-Type=application/json \
                --message-body='{}' \
                --oauth-service-account-email="$CB_SA" \
                --project={{project}}; \
        fi
    @echo "✓ Autobuild wired. Schedule: {{autobuild_schedule}} {{autobuild_tz}}"

# Fire the autobuild trigger right now (ignore schedule)
fire-rebuild: _require-autobuild
    @gcloud scheduler jobs run {{autobuild_trigger}} --location={{region}} --project={{project}}
    @echo "✓ Rebuild triggered. Tail progress: just logs-build"

# Tail the most recent Cloud Build
logs-build:
    @BUILD_ID=$(gcloud builds list --region={{region}} --project={{project}} --limit=1 --format='value(id)'); \
        gcloud builds log $BUILD_ID --region={{region}} --project={{project}}

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

_require-autobuild:
    @if [ "{{autobuild}}" != "true" ]; then \
        echo "Autobuild is disabled. Set NETCIDR_AUTOBUILD=true in .env (see .env.example) and re-run 'just bootstrap' first."; \
        exit 1; \
    fi

# Remove the autobuild trigger + scheduler job
destroy-autobuild: _require-autobuild
    @gcloud scheduler jobs delete {{autobuild_trigger}} --location={{region}} --project={{project}} --quiet 2>&1 | tail -2 || true
    @gcloud builds triggers delete {{autobuild_trigger}} --region={{region}} --project={{project}} --quiet 2>&1 | tail -2 || true
