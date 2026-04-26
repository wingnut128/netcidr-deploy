# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Google Cloud Build pipeline that builds the [netcidr](https://github.com/wingnut128/netcidr.git) subnet calculator from upstream source at a pinned git tag, pushes the image to Artifact Registry, and deploys it to Cloud Run. The whole pipeline lives in `cloudbuild.yaml` — no local Docker build, no IaC framework.

## Commands

Use the `justfile` (requires [just](https://github.com/casey/just)):

```bash
# One-time setup (idempotent): enables APIs, creates AR repo, grants run.admin
# to the Cloud Build default service account so --allow-unauthenticated sticks.
just bootstrap

# Build + push + deploy with defaults
just deploy

# Pin a specific upstream ref (tag, branch, or commit SHA)
just deploy-ref v0.19.3

# Build + deploy the upstream v2 branch to netcidr-v2
just deploy-v2

# Custom Cargo features
just deploy-features swagger false

# Operate
just url      # print Cloud Run service URL
just logs     # tail recent logs
just destroy  # delete the Cloud Run service (prompts)
```

`just bootstrap` reads the active `gcloud config` project — set it first with `gcloud config set project <id>`.

Under the hood, `just deploy` runs `gcloud builds submit --config=cloudbuild.yaml --no-source`. `--no-source` tells Cloud Build to skip uploading the local directory; the pipeline clones the upstream netcidr repo itself as its first step.

## Architecture

**Zero-cost strategy**: Cloud Run's free tier covers 2M requests + 360K GB-seconds/month with scale-to-zero. Artifact Registry's first 0.5 GB is free. Cloud Build's first 120 build-minutes/day are free.

`cloudbuild.yaml` steps:
1. **clone** — `git clone` of the upstream netcidr repo, then `git checkout $_NETCIDR_REF` (accepts tags, branches, or commit SHAs)
2. **build** — `docker build` with `--build-arg FEATURES=...` and `--build-arg WITH_DASHBOARD=...`, tagged both `:$_NETCIDR_REF` and `:latest`
3. **push** — `docker push --all-tags` to `$_REGION-docker.pkg.dev/$PROJECT_ID/$_AR_REPO/$_IMAGE_NAME`
4. **deploy** — `gcloud run deploy` (create-or-update) with 256Mi / 1 vCPU / concurrency 80 / min=0 / max=3, public (`--allow-unauthenticated`), command args `serve --address 0.0.0.0 --port 8080`

**Bootstrap prerequisite**: the Cloud Build default service account (`<project-number>-compute@developer.gserviceaccount.com`) needs `roles/run.admin` to apply `--allow-unauthenticated`. `roles/run.developer` (Cloud Build's default) can deploy but can't set IAM policy on the service. `just bootstrap` grants this.

## Upstream build args

The upstream `Dockerfile` accepts two build args:

- **`FEATURES`** — Cargo feature list (default: `default` = swagger + dashboard). Useful values: `default`, `swagger`, `""` (slim: no swagger, no dashboard).
- **`WITH_DASHBOARD`** — `true` builds the React SPA, `false` skips it.

Pass via `--substitutions=_FEATURES=...,_WITH_DASHBOARD=...` on `gcloud builds submit`.

## Key Config (Cloud Build substitutions)

| Substitution | Default | Purpose |
|---|---|---|
| `_REGION` | `us-central1` | GCP region for AR + Cloud Run |
| `_AR_REPO` | `netcidr-repo` | Artifact Registry repo name |
| `_IMAGE_NAME` | `netcidr` | Artifact Registry image name |
| `_SERVICE_NAME` | `netcidr` | Cloud Run service name |
| `_NETCIDR_REF` | pinned commit | Upstream git tag/branch/commit to build |
| `_FEATURES` | `default` | Cargo features passed to Rust build |
| `_WITH_DASHBOARD` | `true` | Build React dashboard SPA |

Pass `_NETCIDR_REF=latest` to auto-resolve to the highest upstream semver tag at build time (resolved via `git ls-remote --sort=-version:refname`).

## Manual v2 trigger

The upstream `v2` branch is wired as a separate manual Cloud Build path so it
does not replace the existing `netcidr` service or `netcidr:latest` image.

```bash
just deploy-v2          # one-off submit from this machine
just setup-v2-trigger   # create/update prerequisite repo link + manual trigger
just fire-v2-trigger    # run the trigger manually
just destroy-v2-trigger # remove only the manual v2 trigger
```

The v2 trigger runs `cloudbuild.yaml` with:

```text
_NETCIDR_REF=v2
_IMAGE_NAME=netcidr-v2
_SERVICE_NAME=netcidr-v2
```

## Slack notifications

`notifier/` contains a Python Cloud Run Function that subscribes to the
`cloud-builds` Pub/Sub topic, filters for our netcidr builds, and posts
terminal-state (SUCCESS / FAILURE / TIMEOUT / CANCELLED) events to a Slack
webhook stored in Secret Manager.

## Weekly auto-rebuild

Opt-in via `NETCIDR_AUTOBUILD=true` in `.env`. A Cloud Build manual trigger (backed by this repo via a GitHub App connection) runs `cloudbuild.yaml` with `_NETCIDR_REF=latest`; a Cloud Scheduler job fires the trigger weekly (Mon 09:00 America/New_York by default).

**Prereqs:**
- Cloud Build GitHub connection (one-time, via Console → Cloud Build → Connections). Grant the Google Cloud Build GitHub App access to this repo.

**Setup / teardown:**
```bash
just setup-autobuild     # links repo, creates trigger + scheduler job
just fire-rebuild        # manually fire the trigger right now
just destroy-autobuild   # remove trigger + scheduler job
just logs-build          # tail the most recent build
```

Schedule / timezone are `autobuild_schedule` / `autobuild_tz` variables at the top of the `justfile`.

## Slack notifications

Opt-in via `.env`. Default is **disabled** — `bootstrap` stays minimal and notifier recipes refuse to run.

```bash
# 1. Enable the flag
cp .env.example .env
# edit .env → NETCIDR_NOTIFIER=true

# 2. Re-run bootstrap (adds Cloud Functions/Eventarc/Secret Manager APIs + Pub/Sub topic)
just bootstrap

# 3. Store the webhook (prompts, never echoed) and deploy the function
just setup-slack
just deploy-notifier
```

`setup-slack` is re-run to rotate — it adds a new secret version each time. The function reads `versions/latest` on every invocation, so rotations take effect immediately.

With `NETCIDR_NOTIFIER=false` (or unset), `setup-slack` / `deploy-notifier` / `destroy-notifier` all fail fast with a helpful message.
