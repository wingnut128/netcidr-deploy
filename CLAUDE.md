<!-- BEGIN swamp managed section - DO NOT EDIT -->
# Project

This repository is managed with [swamp](https://github.com/swamp-club/swamp).

## Rules

1. **Search before you build.** When automating AWS, APIs, or any external service: (a) search community extensions with `swamp extension search <query>` — prefer `@swamp/*` official extensions first, (b) search local/installed types with `swamp behavior type search <query>`, (c) if a community extension exists, install it with `swamp extension pull <package>` instead of building from scratch, (d) extend an existing type if it covers the domain but lacks the method you need, (e) only create a custom extension behavior in `extensions/models/` as a last resort. Use the `swamp` skill for guidance. The `command/shell` behavior is ONLY for ad-hoc one-off shell commands, NEVER for wrapping CLI tools or building integrations.
2. **Extend, don't be clever.** When a behavior covers the domain but lacks the method you need, extend it with `export const extension` — don't bypass it with shell scripts, CLI tools, or multi-step hacks. One method, one purpose. Use `swamp behavior type describe <type> --json` to check available methods.
3. **Use the data model.** Once data exists in a behavior (via `lookup`, `start`, `sync`, etc.), reference it with CEL expressions. Don't re-fetch data that's already available.
4. **CEL expressions everywhere.** Wire behaviors together with CEL expressions. Always prefer `data.latest("<name>", "<dataName>").attributes.<field>` over the deprecated `model.<name>.resource.<spec>.<instance>.attributes.<field>` pattern.
5. **Verify before destructive operations.** Always `swamp behavior get <name> --json` and verify resource IDs before running delete/stop/destroy methods.
6. **Prefer fan-out methods over loops.** When operating on multiple targets, use a single method that handles all targets internally (factory pattern) rather than looping N separate `swamp behavior run` calls against the same behavior. Multiple parallel calls against the same behavior contend on the per-behavior lock, causing timeouts. A single fan-out method acquires the lock once and produces all outputs in one execution. Check `swamp behavior type describe` for methods that accept filters or produce multiple outputs.
7. **Extension npm deps are bundled; pin them.** Swamp's bundler inlines all npm packages (except zod) into extension bundles at bundle time. When the extension has a `deno.json`, the `deno.lock` beside it decides which versions are bundled; otherwise the registry's current release does. Always pin explicit versions in `npm:` and `jsr:` import specifiers (e.g., `npm:lodash-es@4.17.21`) — `swamp extension push` warns on unpinned and range specifiers.
8. **Reports for reusable data pipelines.** When the task involves building a repeatable pipeline to transform, aggregate, or analyze behavior output (security reports, cost analysis, compliance checks, summaries), create a report extension. Use the `swamp` skill for guidance.
9. **"Workflow" means a swamp workflow.** In this repository the word "workflow" (and "create/run/execute/validate/debug workflow", "automate", "orchestrate", "automated/nightly job") refers to a swamp workflow — a declarative YAML DAG of behavior-method steps authored via `swamp workflow create`. Load and follow the `swamp` skill for these requests. Do NOT interpret these as a request to build an agent task list, spin up worktrees, or schedule a cron/remote agent. Only use those orchestration mechanisms when the user explicitly names one (e.g. "task list", "subagent", "worktree", "cron", "remote agent") or explicitly asks you to do the work yourself step by step rather than author a swamp workflow.
10. **Use swamp, don't bypass it.** Always work through swamp commands — don't go around them with raw shell tools. Use `swamp data query` to find data, not `grep`/`find` on `.swamp/` files. Use behavior methods to interact with resources, not `curl`/`aws`/`gcloud`/`kubectl` when a behavior type already wraps that API — check with `swamp behavior type search`. Use `swamp help` for CLI discovery, not guesswork. Composing with swamp output is fine (e.g. piping `--json` through `jq`) — the anti-pattern is bypassing swamp entirely.
11. **Inspect reports after failures.** When a behavior method or workflow run fails, inspect its generated reports before retrying or changing definitions. Reports run even on failure and capture structured diagnostics — error messages, execution status, arguments, and data output pointers. Use `swamp report get @swamp/method-summary --model <model> --json` for method failures or `swamp report get @swamp/workflow-summary --workflow <workflow> --json` for workflow failures. Run `swamp help report get` to confirm current retrieval syntax.

## Skills

**IMPORTANT:** Always load swamp skills, even when in plan mode. The skills provide
essential context for working with this repository.

- `swamp` - Swamp CLI — behaviors, workflows, data, vaults, extensions, publishing, repos, reports, issues, and troubleshooting
- `swamp-getting-started` - Interactive onboarding for new swamp users

## Getting Started

If you were asked to read a task brief under `tasks/` (a file whose first
line is `<!-- swamp start brief v1 -->`), read that brief, then invoke the
`swamp-getting-started` skill and follow it from its brief entry point.

If the user is new to swamp or asks to get started, or a swamp command you
run shows this repository has no behaviors yet, invoke the
`swamp-getting-started` skill. It checks for existing behaviors itself and walks
new users through an interactive onboarding tutorial.

Otherwise, use the `swamp` skill to work with swamp behaviors.

## Commands

Use `swamp --help` to see available commands. For a machine-readable JSON
schema of the CLI (commands, options, arguments) intended for agent
consumption, run `swamp help [<command>...]` — e.g. `swamp help` returns
the full tree, and `swamp help behavior run` scopes to a subtree.

Behaviors (formerly models) are managed with `swamp behavior` — e.g.
`swamp behavior run <name> <method>` (or
`swamp behavior run @<type> <method> <name>` to run against a type
directly). Every `swamp model …` spelling remains supported.
<!-- END swamp managed section -->

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

## Deploying locally (swamp)

The swamp `deploy` workflow (`workflows/workflow-deploy.yaml`) builds, audits and deploys from this machine, reading the same 1Password items as `aws/samconfig.toml.tpl` through the `netcidr` vault (`netcidr-deployment` in 1Password):

```bash
aws sso login --profile netcidr-admin
AWS_PROFILE=netcidr-admin swamp workflow run deploy                      # newest v* tag
AWS_PROFILE=netcidr-admin swamp workflow run deploy --input ref=v0.33.2  # specific ref
AWS_PROFILE=netcidr-admin swamp workflow run deploy --input force=true   # redeploy the live commit
```

Steps: `build` (cargo-lambda in a worktree under `~/Library/Caches/netcidr-deploy`) → `audit` → `security-gate` → `live-before` (`/version`) → `package` (zip to SAM's bucket, keyed by sha256) → `plan` (CloudFormation change set) → `approve` → `apply` → `dns` (gray-cloud CNAME upsert) → `verify` (`/version` serves the built commit).

- **Security gate.** An unaccepted high, critical or unknown-severity advisory in the shipped Rust crates, the dashboard, or cargo-lambda stops the run before any AWS change. Read the findings and fixes with `swamp report get @dr_evil/netcidr-security --model netcidr-artifact --markdown`. Accept an advisory in netcidr's `deny.toml` (the fix belongs upstream), or temporarily via `acceptedAdvisories` (id, reason, expires) in `models/@dr_evil/netcidr-lambda-artifact/netcidr-artifact.yaml`. Tool pins (Zig, cargo-lambda) move only for security or compatibility reasons.
- **Approval.** The run pauses at `approve`. Review the change set with `swamp data query 'modelName == "netcidr-stack" && name == "changeSet"' --select content`, then `swamp workflow approve deploy approve --run <id>` and `AWS_PROFILE=netcidr-admin swamp workflow resume deploy --run <id>` (the run suspends; approval alone doesn't restart it). An empty plan skips approval.
- **Skip.** If `/version` already reports the built commit, everything from `package` on is skipped.
- A code-only release plans as `NetcidrFunction` plus two "Dynamic" cascades (`NetcidrFunctionExpirySweep`, `...Permission`) through `NetcidrFunction.Arn`; the ARN doesn't change, so those are no-ops.

### Release notifications

The `release-watch` workflow compares netcidr's newest published GitHub release with what `/version` serves, and posts to Discord once per release that isn't deployed yet. Deploying stays manual.

- A launchd agent runs it every 30 minutes: `launchd/dev.cloudreaper.netcidr-release-watch.plist`, installed in `~/Library/LaunchAgents/`, logging to `~/Library/Logs/swamp/netcidr-release-watch.log`. Remove it with `launchctl bootout gui/$(id -u)/dev.cloudreaper.netcidr-release-watch`.
- It reads only public endpoints. The Discord webhook URL is in the local `default` vault (`discord-netcidr-webhook`), not 1Password, because an unattended run can't answer 1Password's approval prompt. Rotate it with `pbpaste | swamp vault put default discord-netcidr-webhook`.
- Run it by hand with `swamp workflow run release-watch`; inspect the last check with `swamp data query 'modelName == "netcidr-release-watch" && name == "status"' --select content`.

## Secrets handling

Two patterns supported:

1. **Plaintext files** (gitignored): copy `samconfig.toml.example` → `samconfig.toml`, `.env.example` → `.env`, fill in values.
2. **1Password-templated** (recommended): save the config as `samconfig.toml.tpl` with `op://...` references and `.env` with `op://...` references. `just deploy` runs `op inject` to render the .tpl into a real samconfig before SAM, then deletes the rendered file on exit (success or failure) via `trap`. Cloudflare recipes use `op run --env-file=.env`.

Both `aws/samconfig.toml` and `aws/samconfig.toml.tpl` are gitignored.

## Key parameters

| Parameter | Where it goes | Notes |
|---|---|---|
| `DatabaseUrl` | samconfig | Neon connection string with `?sslmode=require` |
| `PatPepper` | samconfig | Stable base64url-no-pad secret for `NETCIDR_PAT_PEPPER`; changing it invalidates existing PATs |
| `OidcAudience` | samconfig | Google OAuth Web Client ID — also the dashboard's `VITE_OAUTH_WEB_CLIENT_ID`. Keep it a single ID; the template appends the CLI client itself |
| `OidcCliClientId` / `OidcCliClientSecret` | samconfig | Google OAuth **Desktop app** client for `netcidr login`. Both empty (the default) = CLI login off. When set, the server advertises it on `/features` and accepts its tokens |
| _(access control)_ | database | Who may sign in lives in netcidr's users directory (ADR-0006), managed at runtime via the dashboard Users page or `netcidr admin user`. The Lambda pins `NETCIDR_ALLOWLIST_MODE=closed` in `template.yaml`. |
| `PublicHostname` | samconfig | The hostname users hit (e.g. `netcidr.cloudreaper.dev`) |
| `ExpirySweepSchedule` | samconfig (optional) | EventBridge cadence for netcidr's expiry sweep. Default `rate(1 hour)` |
| `RateLimitPerSecond` / `RateLimitBurst` | samconfig or repo variables `RATE_LIMIT_PER_SECOND` / `RATE_LIMIT_BURST` (optional) | netcidr's per-client limiter. Defaults 20 / 50 |
| `ReservedConcurrency` | samconfig or repo variable `RESERVED_CONCURRENCY` (optional) | Function reserved concurrency. Default `0` (unreserved): this account's total limit is 10, all of which AWS keeps unreserved. Raise the Lambda "Concurrent executions" quota, then set e.g. 5 |
| `OriginVerifySecret` | samconfig / 1Password (`origin-verify/secret`) | ≥ 32 random chars; CloudFront sends it as `X-Origin-Verify`. Rotate by deploying a new value; CloudFront and Lambda update together, so expect a few minutes of 403s while edges catch up |
| `CertificateArn` | samconfig | ACM cert ARN — must be in **us-east-1** (CloudFront constraint), regardless of stack region |
| `CLOUDFLARE_API_TOKEN` | .env | Token needs `Zone:DNS:Edit` |
| `CLOUDFLARE_ZONE_ID` | .env | From the zone overview page |
| `CLOUDFLARE_RECORD_NAME` | .env | Subdomain only (e.g. `netcidr` for `netcidr.cloudreaper.dev`) |
| `CLOUDFLARE_PROXIED` | .env | Must be `false` — gray cloud only. CloudFront terminates user-facing TLS. |

## Architectural decisions baked in

- **No Cloudflare proxy.** Tried it; Cloudflare's free plan can't rewrite the `Host` header (Transform Rules API explicitly blocks it — error 20087: "set is not a valid value for operation because it cannot be used on header 'Host'"). Without the rewrite, CloudFront 403s any request whose Host doesn't match its alias. With the proper Alias + ACM cert, CloudFront accepts the public hostname directly.
- **No CloudFront Origin Shield, no Lambda@Edge.** Both have separate cost. Not needed here.
- **Expiry sweep on an hourly EventBridge schedule.** netcidr releases allocations past their TTL and deletes expired idempotency keys and PATs when the Lambda is invoked with an EventBridge Scheduled Event (netcidr #497). SAM's `Schedule` event creates the rule (`netcidr-expiry-sweep`) and its invoke permission. Hourly rather than every few minutes because each run wakes Neon, which only scales to zero after ~5 idle minutes; a tight schedule would keep it awake all day. The binary must include netcidr #501, or each tick logs a failed HTTP parse.
- **`OriginRequestPolicy: AllViewerExceptHostHeader`** strips Host before forwarding to Lambda. Lambda Function URLs match by URL, but reject any Host that isn't theirs.
- **Rate limiting keys on `CloudFront-Viewer-Address`.** netcidr's per-IP limiter (20 req/s, burst 50) trusts exactly one address source. `NETCIDR_CLIENT_IP_SOURCE=header:cloudfront-viewer-address` points it at the viewer address CloudFront adds; the `AllViewerExceptHostHeader` policy already forwards it. `X-Forwarded-For` would be wrong: CloudFront *appends* to whatever the client sent, so its left side is spoofable (netcidr ADR-0005 amendment).
- **The limiter's bucket is per Lambda instance, so reserved concurrency bounds it.** Each execution environment keeps its own in-memory token bucket and serves one request at a time, so parallel requests fan out to fresh instances with full buckets: the effective per-client limit is `RateLimitPerSecond × instances`. Today the account's total concurrency limit of 10 already caps the function at 10 instances (and cost). With a raised quota, `ReservedConcurrency` (e.g. 5) caps the instance count instead; beyond it Lambda itself returns 429. A sequential client slower than the refill rate (e.g. a `curl` loop over CloudFront at ~10 req/s vs 20 req/s) never sees a 429 at all, which is expected, not a bug. Real per-client limiting across instances needs shared state (Postgres counter: an extra write per request and more Neon wake-ups; or AWS WAF rate rules: ~$5–6/mo) and is deliberately not done.
- **The Function URL only answers CloudFront.** The Function URL itself is public (`AuthType: NONE`), so CloudFront adds a secret `X-Origin-Verify` header (`OriginVerifySecret`) and netcidr (`NETCIDR_ORIGIN_SECRET`) returns 403 to anything without it. Always on: there's no rollout toggle, so the deploy that first adds or changes the secret 403s requests through not-yet-updated edges for a few minutes. CloudFront origin access control (OAC) is **not** usable here: for Lambda origins it replaces the viewer's `Authorization` header with a SigV4 signature (netcidr authenticates with `Authorization: Bearer`) and requires every POST/PUT client to send `x-amz-content-sha256`.
- **The Lambda binary is glibc, not musl.** `cargo lambda build --arm64` passes no explicit `--target`, so it resolves to `aarch64-unknown-linux-gnu` (`TARGET_ARM` in cargo-lambda's `target_arch.rs`). This works because Zig links against an older glibc than the build host has — bridging the build host (arm64 macOS) down to AL2023's glibc 2.34; the swamp build pins the `aarch64-unknown-linux-gnu.2.28` target. Cross-compiling is unavoidable: Lambda is arm64 Linux. That's why `just install-tools` installs Zig.

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
