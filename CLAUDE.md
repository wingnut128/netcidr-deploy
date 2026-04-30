# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS-based deployment for the [netcidr](https://github.com/wingnut128/netcidr.git) subnet calculator. The whole AWS surface is one CloudFormation stack via SAM:

- **Lambda** (arm64, `provided.al2023`) running the Rust netcidr binary built with the `lambda` feature.
- **Lambda Function URL** as the origin endpoint.
- **CloudFront** distribution with the public hostname as an Alias and an ACM cert covering it. CloudFront strips the `Host` header (managed `AllViewerExceptHostHeader` policy) so Lambda sees its own URL as Host and routes correctly.
- **CloudWatch log group** with explicit retention.

Cloudflare hosts the DNS in **gray-cloud (DNS-only) mode** — no proxy, no Workers, no paid Cloudflare features. Postgres for the IPAM backend lives on **Neon** (free tier, scales-to-zero).

**Cost target:** $0/mo at this traffic level.

## Where the code lives

```
aws/
├── template.yaml                  SAM/CloudFormation: Lambda + Function URL + log group + CloudFront
├── samconfig.toml.example         Stack parameters (DatabaseUrl, OidcAudience, PublicHostname, CertificateArn, …)
├── .env.example                   Cloudflare token + zone for the DNS sync + cert bootstrap
├── justfile                       Recipes: install-tools, doctor, build, deploy, ship, cert-bootstrap, destroy
├── README.md                      First-time setup walkthrough
└── cloudflare/
    ├── update-dns.sh              Idempotent CNAME upsert (gray cloud)
    └── bootstrap-cert.sh          One-time ACM cert request + Cloudflare DNS validation
```

The Rust Lambda binary lives in the `netcidr` source repo at `src/bin/lambda.rs`, gated behind the `lambda` Cargo feature. `aws/justfile`'s `build` recipe invokes `cargo lambda build` against that crate; the SAM template's `CodeUri` points at the resulting `target/lambda/lambda/bootstrap`.

## Commands

All work happens inside `aws/`:

```bash
cd aws
just install-tools     # one-time: zig + cargo-lambda + sam CLI
just doctor            # sanity-check tooling, AWS creds, samconfig.toml, .env
just cert-bootstrap    # one-time: provision ACM cert, auto-validate via Cloudflare DNS
just deploy            # build + sam deploy (renders samconfig.toml.tpl via op inject if present)
just cloudflare-sync   # upsert CNAME pointing at CloudFront (gray cloud)
just ship              # deploy + cloudflare-sync in one shot
just url               # print the public URL
just logs              # tail Lambda logs
just destroy           # delete the CFN stack (prompts)
```

`just deploy` and `just cloudflare-sync` are typically wrapped in `op run --env-file=.env -- ...` so 1Password injects secrets at invocation time.

## Deploying from CI (GitHub Actions)

`.github/workflows/deploy.yml` mirrors `just deploy` but runs in GitHub Actions, authenticating to AWS via OIDC (no static keys) and pulling deploy secrets from 1Password via a service account. Triggered manually via the Actions tab (`workflow_dispatch`) with optional inputs `netcidr_ref` (default `main`) and `stack_name`.

### One-time setup

**1. Bootstrap the AWS IAM role + OIDC trust:**
```bash
cd aws && just oidc-bootstrap
# If the GH OIDC provider already exists in the account: just oidc-bootstrap false
```
Outputs `RoleArn`. Save it into the 1Password vault as a new item:
- Vault: `netcidr-deployment`
- Item: `aws-deploy-role`
- Field: `arn`

**2. Create a 1Password service account:**
- 1Password → Integrations → Service Accounts → Create
- Scope: read-only on the `netcidr-deployment` vault
- Copy the token (shown once); store as repo secret `OP_SERVICE_ACCOUNT_TOKEN`
- See [1Password's GitHub Actions docs](https://developer.1password.com/docs/ci-cd/github-actions/)

**3. Configure GitHub repo settings (Settings → Secrets and variables → Actions):**
- **Secrets**: `OP_SERVICE_ACCOUNT_TOKEN`
- **Variables**: `AWS_REGION`, `PUBLIC_HOSTNAME`, `OIDC_ALLOWED_EMAILS`, `ADMIN_EMAILS`, `CLOUDFLARE_RECORD_NAME`

**4. Trigger** (any of):
- Actions → "Deploy" → Run workflow (manual, optional `netcidr_ref` override).
- A new `vX.Y.Z` tag is pushed in `wingnut128/netcidr` — the netcidr release workflow fires `repository_dispatch: netcidr-released` here, which auto-deploys with the new tag. Requires netcidr to hold a fine-grained PAT (`DEPLOY_DISPATCH_TOKEN`) with `Actions: read+write` on this repo.

### What lives where

| Setting | Source | Why |
|---|---|---|
| `AWS_ROLE_TO_ASSUME` | 1Password (`aws-deploy-role/arn`) | Sensitive-ish, central rotation |
| `DatabaseUrl` | 1Password (`neon/connect_string`) | Secret |
| `OidcAudience` | 1Password (`gcp-client-id/client_id`) | Secret-ish (treat as such) |
| `CertificateArn` | 1Password (`certificate/arn`) | Sensitive-ish |
| `CLOUDFLARE_API_TOKEN` | 1Password (`cloudflare/api_token`) | Secret — `Zone:DNS:Edit` only |
| `CLOUDFLARE_ZONE_ID` | 1Password (`cloudflare/zone_id`) | Not really sensitive, but kept with token |
| `CLOUDFLARE_RECORD_NAME` | Repo variable | Subdomain only (e.g. `netcidr`) — public |
| `AWS_REGION`, `PublicHostname`, `OidcAllowedEmails`, `AdminEmails` | Repo variables | Not sensitive, easy to read in run logs |
| `OP_SERVICE_ACCOUNT_TOKEN` | Repo secret | Required to bootstrap 1Password reads |

Vault paths in the workflow exactly mirror those in `aws/samconfig.toml.tpl` so a single rotation in 1Password updates both local (`op inject`) and CI flows.

Cloudflare DNS sync also runs in CI (after `sam deploy`), pulling the API token from the same `netcidr-deployment` vault. Local `just cloudflare-sync` still works for ad-hoc reruns.

## Secrets handling

Two patterns supported:

1. **Plaintext files** (gitignored): copy `samconfig.toml.example` → `samconfig.toml`, `.env.example` → `.env`, fill in values.
2. **1Password-templated** (recommended): save the config as `samconfig.toml.tpl` with `op://...` references and `.env` with `op://...` references. `just deploy` runs `op inject` to render the .tpl into a real samconfig before SAM, then deletes the rendered file on exit (success or failure) via `trap`. Cloudflare recipes use `op run --env-file=.env`.

Both `aws/samconfig.toml` and `aws/samconfig.toml.tpl` are gitignored.

## Key parameters

| Parameter | Where it goes | Notes |
|---|---|---|
| `DatabaseUrl` | samconfig | Neon connection string with `?sslmode=require` |
| `OidcAudience` | samconfig | Google OAuth Web Client ID — also the dashboard's `VITE_OAUTH_WEB_CLIENT_ID` |
| `OidcAllowedEmails` | samconfig | Comma-separated email allowlist for `/ipam/*` |
| `PublicHostname` | samconfig | The hostname users hit (e.g. `netcidr.cloudreaper.dev`) |
| `CertificateArn` | samconfig | ACM cert ARN — must be in **us-east-1** (CloudFront constraint), regardless of stack region |
| `CLOUDFLARE_API_TOKEN` | .env | Token needs `Zone:DNS:Edit` |
| `CLOUDFLARE_ZONE_ID` | .env | From the zone overview page |
| `CLOUDFLARE_RECORD_NAME` | .env | Subdomain only (e.g. `netcidr` for `netcidr.cloudreaper.dev`) |
| `CLOUDFLARE_PROXIED` | .env | Must be `false` — gray cloud only. CloudFront terminates user-facing TLS. |

## Architectural decisions baked in

- **No Cloudflare proxy.** Tried it; Cloudflare's free plan can't rewrite the `Host` header (Transform Rules API explicitly blocks it — error 20087: "set is not a valid value for operation because it cannot be used on header 'Host'"). Without the rewrite, CloudFront 403s any request whose Host doesn't match its alias. With the proper Alias + ACM cert, CloudFront accepts the public hostname directly.
- **No CloudFront Origin Shield, no Lambda@Edge.** Both have separate cost. Not needed here.
- **`OriginRequestPolicy: AllViewerExceptHostHeader`** strips Host before forwarding to Lambda. Lambda Function URLs match by URL, but reject any Host that isn't theirs.
- **Rate limiter disabled in Lambda.** `tower_governor` needs `ConnectInfo<SocketAddr>`, which `lambda_http::run` doesn't provide — `rate_limit_per_second = 0` in the Lambda's `ServerConfig` skips the layer. AWS Lambda's own concurrency controls cover throttling.
- **`sqlx` built with `tls-rustls`.** Neon (any cloud Postgres) requires TLS. Pure Rust, no system openssl dep — keeps the static musl Lambda build clean.

## Common operations

```bash
# Just redeploy after code changes
cd aws && just ship

# Inspect live config
aws lambda get-function-configuration --function-name netcidr --region us-east-2 \
  --query 'Environment.Variables'

# Look at logs from the last hour without tailing
cd aws && just logs-recent

# Tear it all down
cd aws && just destroy           # deletes CFN stack
# (cert and Cloudflare CNAME survive — manually clean up if you want them gone)
```
