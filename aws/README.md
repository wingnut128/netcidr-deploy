# netcidr — AWS deploy (SAM + Cloudflare)

Lambda-based deployment for netcidr v2. The whole AWS surface is one
CloudFormation stack: a Lambda function, its Function URL, a log group,
and a CloudFront distribution that fronts the Function URL. Cloudflare's
free proxy points at CloudFront. No API Gateway, no VPC, no NAT Gateway.

**Why CloudFront is in the path:** Lambda Function URLs only answer
requests where TLS SNI matches their own `<id>.lambda-url.<region>.on.aws`
hostname. Cloudflare's free plan can't rewrite SNI, so a direct
Cloudflare → Function URL CNAME hits the origin with the wrong SNI and
gets a generic edge response. CloudFront accepts arbitrary SNI on its
default cert and rewrites the Host header to the origin's hostname. AWS-
native, no Worker.

**Cost target:** $0/mo.

| Layer | Service | Free? |
|---|---|---|
| Compute | Lambda + Function URL | 1M req/mo + 400k GB-s/mo, indefinitely |
| CDN/edge AWS-side | CloudFront | 1 TB out + 10M req/mo, **always free** (not the 12-month tier) |
| Database | [Neon](https://neon.tech) Postgres | 0.5 GB tier, indefinitely |
| Edge proxy | Cloudflare (free plan, proxy on) | yes |
| TLS (user-facing) | Cloudflare-issued | yes |
| DNS | Cloudflare | yes |

Replaces the GCP/Cloud Run/Spacelift stack under `../terraform/v2/`. That
tree is left in place for now; it can be deleted once this stack is
confirmed working.

## First-time setup

```sh
# 1. Install tools (one-time, macOS)
just install-tools

# 2. Copy and edit local config
cp samconfig.toml.example samconfig.toml      # AWS deploy params
cp .env.example .env                          # Cloudflare token, zone, etc.

# Or, if you keep secrets in 1Password (recommended):
#   - Save your config to samconfig.toml.tpl with `op://Vault/Item/field`
#     references in place of literal values.
#   - `just deploy` renders the .tpl via `op inject` before deploying and
#     removes the rendered samconfig.toml afterward (even on failure).
#   - For .env, run with `op run --env-file=.env -- just <recipe>` so
#     CLOUDFLARE_API_TOKEN etc. are injected at invocation time.

# 3. Verify environment
just doctor

# 4. Stand up Neon (manually for now, or via the Neon MCP if wired in
#    Claude Code). Grab the connection string and paste it into
#    samconfig.toml under DatabaseUrl.

# 5. Deploy
just deploy-guided          # first time — writes deployment defaults
just cloudflare-sync        # point your Cloudflare CNAME at CloudFront
just cloudflare-host-rule   # rewrite Host header so CloudFront accepts the proxied request
```

After that, `just ship` rebuilds + redeploys + syncs DNS + reapplies the Host rule in one shot.

## What's where

```
aws/
├── template.yaml              SAM/CloudFormation: Lambda + Function URL + log group
├── samconfig.toml.example     Stack parameters (DatabaseUrl, OidcAudience, …)
├── .env.example               Cloudflare token + zone for the DNS sync
├── justfile                   Recipes: install-tools, build, deploy, ship, destroy
└── cloudflare/
    └── update-dns.sh          Idempotent CNAME upsert via Cloudflare API
```

The Rust Lambda binary lives in the `netcidr` source repo under
`src/bin/lambda.rs` (built with `cargo lambda`). `just build` compiles it
into `<netcidr-repo>/target/lambda/lambda/bootstrap`, which `template.yaml`
picks up via `CodeUri`.

## Configuration that lives outside this directory

These are one-time clicks not worth automating:

- **Google OAuth Web Client** (Google Cloud Console → APIs & Services →
  Credentials). Add your Cloudflare-fronted hostname to "Authorized
  JavaScript origins" and `https://<host>/auth/callback` to "Authorized
  redirect URIs". The client ID goes into `OidcAudience`.
- **Neon project.** Create at [neon.tech](https://neon.tech) → grab the
  pooled connection string → paste into `DatabaseUrl`.
- **Cloudflare API token.** Zone-level token with `Zone:DNS:Edit`. Paste
  into `.env`.

## Operate

```sh
just url                # print the raw Function URL
just logs               # tail Lambda logs
just logs-recent        # last hour, no follow
just console            # open the CFN stack in the AWS console
just destroy            # delete everything (prompts for confirmation)
```

## Tradeoffs

- **No CloudFront.** Cloudflare proxies directly to the Function URL.
  Saves a service and avoids the 12-mo CloudFront free-tier cliff. If you
  need AWS-side WAF, signed URLs, or you decide to stop paying Cloudflare,
  add a `AWS::CloudFront::Distribution` resource to the template.
- **Public-facing Postgres.** Neon's connection is over the public
  internet (TLS). For an admin IPAM tool that's fine; for higher
  sensitivity move to RDS in a VPC and accept the NAT Gateway cost ($32/mo).
- **No state file.** CloudFormation tracks state inside AWS. There is no
  Terraform/HCP/Spacelift to manage.
