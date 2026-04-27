# netcidr v2 Pulumi Stack

Pulumi-managed GCP stack for `netcidr-v2` on Cloud Run with Cloud SQL Postgres,
Secret Manager, Artifact Registry, Cloud Build, and direct Cloud Run IAP.

## Configure

```bash
cd infra/v2
npm install
pulumi stack init dev
pulumi config set gcp:project <project-id>
pulumi config set region us-central1
```

Alternatively, set the project as stack-local config:

```bash
pulumi config set project <project-id>
```

The Cloud Build trigger assumes the existing Cloud Build v2 GitHub connection:

```text
projects/<project-id>/locations/<region>/connections/github-connection/repositories/netcidr-deploy
```

Override with:

```bash
pulumi config set buildTriggerName netcidr-v2-pulumi-build
pulumi config set cloudBuildConnection <connection-name>
pulumi config set cloudBuildRepository <repository-name>
pulumi config set cloudBuildBranch main
```

If you use a custom Cloud Run domain, make it stack config so Pulumi keeps the
mapping attached to this service:

```bash
pulumi config set customDomain netcidr-v2.example.com
```

For a domain mapping that already exists from a manual Cloud Run update, import
it before `pulumi up`:

```bash
pulumi import gcp:cloudrun/domainMapping:DomainMapping netcidr-v2-domain \
  locations/us-central1/namespaces/<project-id>/domainmappings/netcidr-v2.example.com
```

## IAP OAuth

By default, this stack enables direct Cloud Run IAP without custom OAuth
credentials. That lets IAP use Google-managed OAuth where available, keeping an
OAuth client secret out of your workstation and out of Pulumi state.

Google-managed OAuth is for browser access by users in the same Google
Workspace or Cloud Identity organization as the project. Standalone projects
without an organization generally need a custom OAuth client.

If the project has never had IAP enabled from the Console, first-time setup can
still require one Console initialization pass. Until that exists, the service
can return:

```text
Empty Google Account OAuth client ID(s)/secret(s).
```

Use the Cloud Run Console to enable IAP once for the service/project, then keep
the rest of the service, IAM, and environment guardrails managed by Pulumi.

### Custom OAuth Override

Only use a custom OAuth client when Google-managed OAuth does not meet the
access requirement, for example external users, custom branding, or
programmatic access requirements.

You can pass the client secret directly as Pulumi secret config:

```bash
pulumi config set iapOauthClientId <oauth-client-id>
pulumi config set --secret iapOauthClientSecret <oauth-client-secret>
pulumi up
```

Or store the secret in Secret Manager first:

```bash
printf '%s' '<oauth-client-secret>' | gcloud secrets create netcidr-v2-iap-oauth-client-secret \
  --data-file=- \
  --project=<project-id>

pulumi config set iapOauthClientId <oauth-client-id>
pulumi config set iapOauthClientSecretSecretId netcidr-v2-iap-oauth-client-secret
pulumi up
```

Use `gcloud secrets versions add` to rotate an existing secret. Set
`iapOauthClientSecretVersion` if you want Pulumi to pin a specific version
instead of `latest`.

Pulumi reads the Secret Manager value and applies it to the IAP settings for
this regional Cloud Run service. The value is treated as a Pulumi secret, but it
must still enter encrypted Pulumi state because the IAP API requires the OAuth
secret value when configuring the service.

## Hardening Defaults

The stack staples the key environment guardrails into code:

- Single-purpose runtime and build service accounts.
- No `allUsers` or `allAuthenticatedUsers` Cloud Run invoker binding.
- Direct Cloud Run IAP enabled on the service.
- Optional Cloud Run custom domain mapping owned by Pulumi.
- IAP service agent gets only `roles/run.invoker` on this service.
- Runtime service account gets only `roles/cloudsql.client` and secret-level access to the DB URL.
- Build service account gets Artifact Registry writer on this repository, Cloud Run admin for deployment, and `iam.serviceAccountUser` only on the runtime service account.
- Cloud SQL, Cloud Run, and the DB URL secret use deletion protection by default.

Optional project org-policy guardrails can be enabled when this is a dedicated
environment project and the Pulumi identity has org-policy permissions:

```bash
pulumi config set enforceProjectOrgPolicies true
```

That enforces:

- `constraints/iam.disableServiceAccountKeyCreation`
- `constraints/iam.disableServiceAccountKeyUpload`
- `constraints/iam.automaticIamGrantsForDefaultServiceAccounts`

## Deploy

```bash
pulumi preview
pulumi up
pulumi stack output runBuildTriggerCommand
```

Run the emitted trigger command to build upstream `netcidr` `v2` with
`default,ipam-postgres` features and update only the Cloud Run service image.
Pulumi ignores image drift so Cloud Build can roll the app forward while Pulumi
continues to own infrastructure and environment guardrails.

## IAP Notes

This stack uses direct Cloud Run IAP via `gcp.cloudrunv2.Service.iapEnabled`.
It grants `roles/run.invoker` to the IAP service agent:

```text
service-<project-number>@gcp-sa-iap.iam.gserviceaccount.com
```

If an older Pulumi GCP provider lacks `iapEnabled`, upgrade `@pulumi/gcp`.
The minimal workaround is:

```bash
gcloud beta services identity create --service=iap.googleapis.com --project=<project-id>
gcloud run services add-iam-policy-binding netcidr-v2 \
  --region=<region> \
  --member=serviceAccount:service-<project-number>@gcp-sa-iap.iam.gserviceaccount.com \
  --role=roles/run.invoker
gcloud beta run services update netcidr-v2 --region=<region> --iap
```

The expected IAP signed-header audience is exported as `oidcAudience` and passed
to the app as `NETCIDR_OIDC_AUDIENCE`:

```text
/projects/<project-number>/locations/<region>/services/<service-name>
```

Grant users or groups access with `roles/iap.httpsResourceAccessor` after the
service exists.
