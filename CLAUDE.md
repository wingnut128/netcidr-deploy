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
3. **push** — `docker push --all-tags` to `$_REGION-docker.pkg.dev/$PROJECT_ID/$_AR_REPO/netcidr`
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
| `_SERVICE_NAME` | `netcidr` | Cloud Run service name |
| `_NETCIDR_REF` | `v0.19.3` | Upstream git tag/branch to build |
| `_FEATURES` | `default` | Cargo features passed to Rust build |
| `_WITH_DASHBOARD` | `true` | Build React dashboard SPA |

Pass `_NETCIDR_REF=latest` to auto-resolve to the highest upstream semver tag at build time (resolved via `git ls-remote --sort=-version:refname`).

## Slack notifications

`notifier/` contains a Python Cloud Run Function that subscribes to the
`cloud-builds` Pub/Sub topic, filters for our netcidr builds, and posts
terminal-state (SUCCESS / FAILURE / TIMEOUT / CANCELLED) events to a Slack
webhook stored in Secret Manager.

Two commands:

```bash
just setup-slack       # prompts for the webhook (hidden), stores in Secret Manager, grants SA
just deploy-notifier   # deploys the Cloud Run Function subscribed to the cloud-builds topic
```

`setup-slack` is re-run to rotate — it adds a new secret version each time. The function reads `versions/latest` on every invocation, so rotations take effect immediately.

APIs and the `cloud-builds` Pub/Sub topic are provisioned by `just bootstrap` — no separate steps needed.
