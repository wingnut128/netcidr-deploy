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

## Deploying

Deploys run through the swamp `deploy` workflow at the repo root
(`workflows/workflow-deploy.yaml`); see the root `CLAUDE.md` for the steps,
the security gate and the approval flow:

```sh
aws sso login --profile netcidr-admin
AWS_PROFILE=netcidr-admin swamp workflow run deploy
```

Stack parameters live in `models/@swamp/aws/cloudformation/stack/netcidr-stack.yaml`,
with secrets read from the `netcidr` vault (1Password `netcidr-deployment`).
The Cloudflare CNAME is upserted by the `dns` step (`netcidr-dns` model).

## What's where

```
aws/
└── template.yaml              SAM/CloudFormation: Lambda + Function URL + log group + CloudFront
```

The Rust Lambda binary lives in the `netcidr` source repo under
`src/bin/lambda.rs` (built with `cargo lambda`). The workflow's `build` step
compiles it and `package` uploads the zip and points `CodeUri` at it.

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
  `client_secret`). The template appends the client ID to
  `NETCIDR_OIDC_AUDIENCE` itself, so leave `OidcAudience` as the Web client
  ID only. If both values are left empty, CLI login stays off and the CLI
  falls back to `NETCIDR_API_TOKEN`. To check it worked, look for an
  `"auth"` block in `GET https://<host>/features`.
- **Neon project.** Create at [neon.tech](https://neon.tech) → grab the
  pooled connection string → store it in 1Password
  `netcidr-deployment/neon` (`connect_string`).
- **PAT pepper.** Generate one base64url-no-pad value
  (`openssl rand -base64 32 | tr '+/' '-_' | tr -d '='`) and store it in
  `netcidr-deployment/pat-pepper` (`value`). Keep it stable; changing it invalidates existing PATs.
- **Cloudflare API token.** Zone-level token with `Zone:DNS:Edit`. Store it in
  `netcidr-deployment/cloudflare` (`api_token`, plus `zone_id`).
- **ACM certificate** for the public hostname, in **us-east-1**,
  DNS-validated through Cloudflare. ACM renews it automatically while the
  validation CNAME stays in place. Its ARN goes in
  `netcidr-deployment/certificate` (`arn`).

## Operate

```sh
export AWS_PROFILE=netcidr-admin AWS_REGION=us-east-2
sam logs --stack-name netcidr --tail                       # tail Lambda logs
sam logs --stack-name netcidr --start-time '1 hour ago'    # last hour, no follow
aws cloudformation describe-stacks --stack-name netcidr \
  --query 'Stacks[0].Outputs'                              # CloudFront domain, Function URL
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
without it (403). It is always on.

1. Create the 1Password item `netcidr-deployment/origin-verify` with a
   `secret` field of at least 32 random characters (e.g.
   `openssl rand -base64 48 | tr -d '/+=' | cut -c1-48`).
2. Deploy. The Lambda starts enforcing immediately, while CloudFront takes a
   few minutes to roll the header out to every edge; requests through an
   edge that hasn't caught up get 403 until it does. The same applies when
   rotating the secret, so do either at a quiet moment.
3. Once the distribution's status is `Deployed`, check that the raw
   Function URL refuses and the public hostname works:

   ```sh
   fn_url=$(aws cloudformation describe-stacks --stack-name netcidr \
     --query 'Stacks[0].Outputs[?OutputKey==`FunctionUrl`].OutputValue' --output text)
   curl -s -o /dev/null -w '%{http_code}\n' "${fn_url}health"       # 403
   curl -s -o /dev/null -w '%{http_code}\n' https://<PublicHostname>/health  # 200
   ```

Rate limiting keys on `CloudFront-Viewer-Address` (see CLAUDE.md), set by
`NETCIDR_CLIENT_IP_SOURCE` in the template.

## Rate limiting

netcidr's limiter (`RateLimitPerSecond` 20, `RateLimitBurst` 50) keeps its
bucket in each Lambda instance's memory, so the effective per-client limit
grows with warm instances (at most 10 while the account concurrency limit
is 10; `ReservedConcurrency` can cap it lower once that quota is raised). A normal `curl` loop is slower than the refill rate
and never gets a 429. To check the limiter is keying on the viewer address,
deploy with a limit a loop *can* exceed, then put it back:

1. Set `RateLimitPerSecond: "1"` and `RateLimitBurst: "3"` in the
   `netcidr-stack` model and deploy.
2. From one machine, expect a few 200s and then 429s:

   ```sh
   for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code} ' https://<PublicHostname>/health; done; echo
   ```

3. Straight after, from another network (e.g. a phone hotspot), expect 200.
   If it's 429, `CloudFront-Viewer-Address` isn't arriving and everyone
   shares one bucket.
4. Back on the first machine, a spoofed header must still get 429:
   `curl -s -o /dev/null -w '%{http_code}\n' -H 'CloudFront-Viewer-Address: 203.0.113.99:1234' https://<PublicHostname>/health`
5. Put them back to `"20"` / `"50"` and deploy.

Several warm instances each hold their own bucket, so a run can
occasionally see a 200 after 429s; a consistent 200 run in step 2 is the
signal that something is wrong.

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
