# netcidr — AWS deploy (SAM + Cloudflare)

Lambda-based deployment for netcidr v2. The whole AWS surface is one
CloudFormation stack: a Lambda function, its Function URL, a log group,
and a CloudFront distribution that serves the public hostname directly.

**Path:** user → Cloudflare DNS (gray cloud, no proxy) → CloudFront →
Lambda Function URL.

**Why CloudFront and not Cloudflare proxy:** Lambda Function URLs only
answer requests where TLS SNI matches their own
`<id>.lambda-url.<region>.on.aws` hostname. Cloudflare's free plan can't
rewrite Host or SNI, so a Cloudflare → Lambda CNAME 403s. CloudFront
sits between, terminates TLS for the public hostname using an ACM cert,
and rewrites Host to the origin before forwarding to Lambda. AWS-native,
no Worker, no paid Cloudflare features.

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
#    samconfig.toml under DatabaseUrl. Generate one stable PAT pepper and
#    paste it into PatPepper:
#    openssl rand -base64 32 | tr '+/' '-_' | tr -d '='

# 5. Provision the ACM cert (one-time — auto-validates against Cloudflare DNS)
op run --env-file=.env -- just cert-bootstrap
# Paste the printed ARN into samconfig.toml.tpl under CertificateArn.

# 6. Deploy
just deploy-guided          # first time — writes deployment defaults
just cloudflare-sync        # point Cloudflare CNAME (gray cloud) at CloudFront
```

After that, `just ship` rebuilds + redeploys + syncs DNS in one shot.

## What's where

```
aws/
├── template.yaml              SAM/CloudFormation: Lambda + Function URL + log group
├── samconfig.toml.example     Stack parameters (DatabaseUrl, PatPepper, OidcAudience, …)
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
- **Google OAuth Desktop Client** (optional, enables `netcidr login`).
  In the same Google Cloud project, create a second OAuth client of type
  **Desktop app**. It needs no redirect URIs, because the CLI uses a loopback
  redirect. Put its client ID and secret in `OidcCliClientId` and
  `OidcCliClientSecret`, or in the 1Password item
  `netcidr-deployment/gcp-cli-client` (fields `client_id` and
  `client_secret`) for CI. The template appends the client ID to
  `NETCIDR_OIDC_AUDIENCE` itself, so leave `OidcAudience` as the Web client
  ID only. If both values are left empty, CLI login stays off and the CLI
  falls back to `NETCIDR_API_TOKEN`. To check it worked, look for an
  `"auth"` block in `GET https://<host>/features`.
- **Neon project.** Create at [neon.tech](https://neon.tech) → grab the
  pooled connection string → paste into `DatabaseUrl`.
- **PAT pepper.** Generate one base64url-no-pad value and paste it into
  `PatPepper`. Keep it stable; changing it invalidates existing PATs.
- **Cloudflare API token.** Zone-level token with `Zone:DNS:Edit`. Paste
  into `.env`.

## Operate

```sh
just url                # print the CloudFront domain
just logs               # tail Lambda logs
just logs-recent        # last hour, no follow
just console            # open the CFN stack in the AWS console
just destroy            # delete everything (prompts for confirmation)
```

**Expiry sweep.** An EventBridge rule (`netcidr-expiry-sweep`, default
`rate(1 hour)`, parameter `ExpirySweepSchedule`) invokes the Lambda so
netcidr releases expired allocation reservations and prunes expired
idempotency keys and PATs. Each run logs an `expiry sweep` line with counts
(only when something changed). To run one now:

```sh
aws lambda invoke --function-name netcidr \
  --payload '{"source":"aws.events","detail-type":"Scheduled Event","detail":{}}' \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

## Origin lockdown

The Function URL is public, so CloudFront proves each request came through
it with a secret `X-Origin-Verify` header, and netcidr rejects requests
without it (403). Roll it out in two deploys so no edge is caught without
the header:

1. Create the 1Password item `netcidr-deployment/origin-verify` with a
   `secret` field of at least 32 random characters (e.g.
   `openssl rand -base64 48 | tr -d '/+=' | cut -c1-48`), or set
   `OriginVerifySecret` in `samconfig.toml`.
2. Deploy with `EnforceOriginSecret=false` (the default). CloudFront starts
   sending the header; wait until the distribution's status is `Deployed`.
3. Set the repo variable `ENFORCE_ORIGIN_SECRET=true` (or
   `EnforceOriginSecret=true` locally) and deploy again.
4. Check that the raw Function URL now refuses and the public hostname
   still works:

   ```sh
   fn_url=$(aws cloudformation describe-stacks --stack-name netcidr \
     --query 'Stacks[0].Outputs[?OutputKey==`FunctionUrl`].OutputValue' --output text)
   curl -s -o /dev/null -w '%{http_code}\n' "${fn_url}health"       # 403
   curl -s -o /dev/null -w '%{http_code}\n' https://<PublicHostname>/health  # 200
   ```

Rate limiting keys on `CloudFront-Viewer-Address` (see CLAUDE.md), set by
`NETCIDR_CLIENT_IP_SOURCE` in the template.

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
