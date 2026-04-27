# netcidr v2 — Terraform stack

Manages the GCP infrastructure for the netcidr v2 service. Net-new replacement
for `infra/v2/` (Pulumi).

**Owns:** Cloud Run service shell, Cloud SQL Postgres (private IP), Secret
Manager secret + version, Artifact Registry repo, runtime + build service
accounts, IAM bindings, VPC peering for Cloud SQL, Cloud Build trigger,
optional custom domain mapping, optional Cloudflare DNS record.

**Does not own:** the Cloud Run container image. The Cloud Build trigger
(`cloudbuild-v2.yaml`) clones upstream netcidr, builds it, pushes to Artifact
Registry, and runs `gcloud run services update --image=...:latest`. Terraform
ignores changes to the image field on subsequent applies.

## Auth model

- IAP is **off**.
- Application-layer auth is enforced on `/ipam/*` only — Google OAuth ID
  tokens validated against `oauth_web_client_id`.
- Calculator / split / contains / summarize / from-range / health / version /
  features stay public.
- `allowed_emails` (optional) gates verified Google identities.
- `enable_public_invoker = true` grants `roles/run.invoker` to `allUsers` so
  Cloudflare (or any public proxy) can reach the service. Default is `false`.

## First-time setup

Apply runs through **Spacelift** (state managed there too). Local-CLI runs
remain possible as a fallback — see the bottom of this doc.

You will need before you start:

- A Google OAuth 2.0 **Web Client ID** (Console → APIs & Services → Credentials
  → Create OAuth Client → Web application). Authorize the dashboard origin
  under "Authorized JavaScript origins."
- The Cloud Build → GitHub connection (`var.deploy_repo_connection`, default
  `github-connection`) wired in the project. Terraform does not create it.
- A Spacelift account with a stack pointing at `terraform/v2/` (see "Spacelift
  onboarding" below).

End-to-end flow once that's in place: push to `main` → Spacelift plans →
confirm → applies. Then trigger Cloud Build to swap the bootstrap image for
the real one, flip the public invoker on, re-apply, re-enable Cloudflare.

## Config file baked into the image

`cloudbuild-v2.yaml` writes a `netcidr.toml` at build time with:

```
allow_public_bind            = true
require_auth_for_public_bind = true
enable_swagger               = true
ipam_enabled                 = true
ipam_backend                 = "postgres"
auth_mode                    = "oidc"
```

The audience and email allowlist are injected as env vars
(`NETCIDR_OIDC_AUDIENCE`, `NETCIDR_OIDC_ALLOWED_EMAILS`), not via the toml.

## State backend

State is managed by **Spacelift** — no `backend` block here. If you ever
abandon Spacelift, drop a backend in:

```hcl
terraform {
  backend "gcs" {
    bucket = "your-tf-state-bucket"
    prefix = "netcidr-v2"
  }
}
```

## Cloudflare DNS (optional)

Setting `cloudflare_zone_id` (and `cloudflare_api_token`) creates a CNAME
in Cloudflare that points `<cloudflare_subdomain>.<zone>` (default
`netcidr-v2.<zone>`) at `ghs.googlehosted.com`, with the orange-cloud
proxy on by default. Leave the zone ID empty to skip — the resource is
guarded by `count = var.cloudflare_zone_id == "" ? 0 : 1`.

To wire it up:

1. Cloudflare dashboard → your zone → "API tokens" (zone-level) → create a
   token with `Zone:DNS:Edit` scoped to just the target zone.
2. In Spacelift stack environment, add (as **secret**, not plain):
   ```
   TF_VAR_cloudflare_api_token = <token>
   TF_VAR_cloudflare_zone_id = <zone-id-from-zone-overview-page>
   ```
3. Trigger a run; Terraform creates the CNAME.

The CNAME plus the Cloud Run domain mapping (`var.custom_domain`) are
the two pieces needed end-to-end. They're independent in this stack —
you can set either without the other if you're staging the cutover.

## Spacelift onboarding

One-time setup, all done in the Spacelift UI (free tier covers this stack):

1. **Connect VCS** — Settings → Source control → add the GitHub integration to
   the org that owns `netcidr-deploy`.

2. **Create the stack:**
   - Name: `netcidr-v2`
   - Repo: `netcidr-deploy`, branch: `main`, project root: `terraform/v2`
   - Backend: Terraform (Spacelift manages state)
   - Terraform version: `1.9.8` (matches `.terraform-version`)
   - Workflow tool: OpenTofu or Terraform — either works; the providers we use
     are vendor-neutral.

3. **Add a GCP cloud integration** — Settings → Cloud integrations → GCP →
   create. Spacelift's UI may surface either an OAuth-flavored or an
   OIDC/WIF-flavored GCP integration depending on which "Add" path you
   click. Two supported flows:

   **OAuth (simplest, what Spacelift's default GCP integration creates):**
   The integration UI shows you a Spacelift-owned SA like
   `gcp-XXXX@us-spacelift.iam.gserviceaccount.com`. Run this once to let it
   impersonate the `spacelift-deployer` SA in your project:
   ```sh
   PROJECT_ID=tasker-487819 \
   SPACELIFT_GCP_SA=gcp-XXXX@us-spacelift.iam.gserviceaccount.com \
     ../../scripts/grant-spacelift-impersonation.sh
   ```
   Then set the stack env var
   `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT=spacelift-deployer@<project>.iam.gserviceaccount.com`.
   The Google provider does the impersonation hop natively.

   **OIDC/WIF (cleaner, no Spacelift-owned SA in your IAM diagram):**
   Run `../../scripts/setup-spacelift-wif.sh` first (creates the
   `spacelift-deployer` SA, Workload Identity Pool, and OIDC provider),
   then in Spacelift's "OIDC" cloud integration form paste the printed
   provider path and SA email. Audience is `<account>.app.<region>.spacelift.io`.

   Bind the integration to the `netcidr-v2` stack either way.

4. **Stack environment variables** — Settings → Environment. Set as plain or
   secret as appropriate:
   - `TF_VAR_project = tasker-487819`
   - `TF_VAR_oauth_web_client_id = <your-web-client-id>.apps.googleusercontent.com`
   - `TF_VAR_allowed_emails = ["you@gmail.com"]` (use Spacelift's JSON list
     syntax, or set via a mounted `terraform.tfvars` file)
   - `TF_VAR_enable_public_invoker = false` initially; flip to `true` after
     the first build deploys a real image.
   - `TF_VAR_custom_domain = netcidr-v2.cloudreaper.dev` (optional)

5. **Worker pool:** the public Spacelift worker is fine for this — no need to
   self-host workers since Cloud SQL is reached via the Admin API + socket
   path through Cloud Run, not directly from Terraform.

6. **Trigger first run:** push to `main` (or click "Trigger" in the Spacelift
   UI). The stack will plan, you confirm, then it applies. The Cloud Run
   service comes up with the bootstrap "hello" image; that's expected.

7. **Push the real image:** trigger Cloud Build separately:
   ```sh
   gcloud builds triggers run netcidr-v2-build \
     --branch=main --region=us-central1 --project=tasker-487819
   ```

8. **Flip the public invoker on:** set `TF_VAR_enable_public_invoker=true`,
   re-run the stack. The next apply grants `allUsers` invoke access. Re-enable
   the Cloudflare proxy in front of the Cloud Run URL.

## Local fallback

If you ever need to run from your laptop (debugging, escape hatch from
Spacelift):
```sh
cd terraform/v2
cp terraform.tfvars.example terraform.tfvars
# edit, then drop a backend "gcs" block in versions.tf or another file
terraform init
terraform plan
```
