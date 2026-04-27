import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";
import * as random from "@pulumi/random";

const config = new pulumi.Config();
const gcpConfig = new pulumi.Config("gcp");
const project = config.get("project") ?? gcpConfig.require("project");
const region = config.get("region") ?? "us-central1";

const names = {
  artifactRepo: config.get("artifactRepo") ?? "netcidr-v2-repo",
  imageName: config.get("imageName") ?? "netcidr-v2",
  service: config.get("serviceName") ?? "netcidr-v2",
  sqlInstance: config.get("sqlInstanceName") ?? "netcidr-v2-db",
  sqlDatabase: config.get("sqlDatabaseName") ?? "netcidr",
  sqlUser: config.get("sqlUserName") ?? "netcidr",
  dbUrlSecret: config.get("dbUrlSecretName") ?? "netcidr-v2-ipam-db-url",
  trigger: config.get("buildTriggerName") ?? "netcidr-v2-pulumi-build",
};

const netcidrRef = config.get("netcidrRef") ?? "v2";
const deployRepoConnection = config.get("cloudBuildConnection") ?? "github-connection";
const deployRepoName = config.get("cloudBuildRepository") ?? "netcidr-deploy";
const deployRepoBranch = config.get("cloudBuildBranch") ?? "main";
const minInstances = config.getNumber("minInstances") ?? 0;
const maxInstances = config.getNumber("maxInstances") ?? 3;
const sqlTier = config.get("sqlTier") ?? "db-f1-micro";
const deletionProtection = config.getBoolean("deletionProtection") ?? true;
const enforceProjectOrgPolicies = config.getBoolean("enforceProjectOrgPolicies") ?? false;
const iapOauthClientId = config.get("iapOauthClientId");
const iapOauthClientSecretConfig = config.getSecret("iapOauthClientSecret");
const iapOauthClientSecretSecretId = config.get("iapOauthClientSecretSecretId");
const iapOauthClientSecretVersion = config.get("iapOauthClientSecretVersion") ?? "latest";
const customDomain = config.get("customDomain");
const bootstrapImage =
  config.get("bootstrapImage") ?? "us-docker.pkg.dev/cloudrun/container/hello";

const labels = {
  app: "netcidr",
  stack: "v2",
  managed_by: "pulumi",
};

const requiredApis = [
  "artifactregistry.googleapis.com",
  "cloudbuild.googleapis.com",
  "run.googleapis.com",
  "secretmanager.googleapis.com",
  "sqladmin.googleapis.com",
  "iap.googleapis.com",
  "iam.googleapis.com",
  "cloudresourcemanager.googleapis.com",
  "orgpolicy.googleapis.com",
];

const services = requiredApis.map(
  (service) =>
    new gcp.projects.Service(service.replace(/[.]/g, "-"), {
      project,
      service,
      disableOnDestroy: false,
    }),
);

function booleanProjectPolicy(name: string, constraint: string) {
  if (!enforceProjectOrgPolicies) {
    return undefined;
  }

  return new gcp.orgpolicy.Policy(
    name,
    {
      name: `projects/${project}/policies/${constraint}`,
      parent: `projects/${project}`,
      spec: {
        rules: [
          {
            enforce: "TRUE",
          },
        ],
      },
    },
    { dependsOn: services },
  );
}

booleanProjectPolicy("disable-service-account-key-creation", "iam.disableServiceAccountKeyCreation");
booleanProjectPolicy("disable-service-account-key-upload", "iam.disableServiceAccountKeyUpload");
booleanProjectPolicy(
  "disable-default-service-account-editor-grants",
  "iam.automaticIamGrantsForDefaultServiceAccounts",
);

const projectInfo = pulumi.output(gcp.organizations.getProject({ projectId: project }));
const projectNumber = projectInfo.number.apply(String);

const imageRepo = new gcp.artifactregistry.Repository(
  "netcidr-v2-repo",
  {
    project,
    location: region,
    repositoryId: names.artifactRepo,
    description: "Docker images for netcidr v2",
    format: "DOCKER",
    labels,
  },
  { dependsOn: services },
);

const runtimeSa = new gcp.serviceaccount.Account(
  "netcidr-v2-runtime",
  {
    project,
    accountId: "netcidr-v2-run",
    displayName: "netcidr v2 Cloud Run runtime",
    description: "Single-purpose runtime identity for the netcidr v2 Cloud Run service.",
  },
  { dependsOn: services },
);

const buildSa = new gcp.serviceaccount.Account(
  "netcidr-v2-build",
  {
    project,
    accountId: "netcidr-v2-build",
    displayName: "netcidr v2 Cloud Build deployer",
    description: "Single-purpose build identity for the Pulumi-managed netcidr v2 Cloud Build trigger.",
  },
  { dependsOn: services },
);

const dbPassword = new random.RandomPassword("netcidr-v2-db-password", {
  length: 32,
  special: false,
});

const sqlInstance = new gcp.sql.DatabaseInstance(
  "netcidr-v2-postgres",
  {
    project,
    region,
    name: names.sqlInstance,
    databaseVersion: "POSTGRES_16",
    deletionProtection,
    settings: {
      tier: sqlTier,
      edition: "ENTERPRISE",
      availabilityType: "ZONAL",
      diskType: "PD_SSD",
      diskSize: 10,
      diskAutoresize: true,
      backupConfiguration: {
        enabled: true,
        startTime: "09:00",
      },
      ipConfiguration: {
        ipv4Enabled: true,
      },
      userLabels: labels,
    },
  },
  { dependsOn: services, protect: deletionProtection },
);

const database = new gcp.sql.Database("netcidr-v2-db", {
  project,
  instance: sqlInstance.name,
  name: names.sqlDatabase,
});

const dbUser = new gcp.sql.User("netcidr-v2-db-user", {
  project,
  instance: sqlInstance.name,
  name: names.sqlUser,
  password: dbPassword.result,
});

const dbUrl = pulumi
  .all([dbUser.name, dbPassword.result, database.name, sqlInstance.connectionName])
  .apply(
    ([user, password, dbName, connectionName]) =>
      `postgresql://${user}:${password}@/${dbName}?host=/cloudsql/${connectionName}`,
  );

const dbUrlSecret = new gcp.secretmanager.Secret(
  "netcidr-v2-db-url-secret",
  {
    project,
    secretId: names.dbUrlSecret,
    labels,
    replication: {
      auto: {},
    },
  },
  { dependsOn: services, protect: deletionProtection },
);

new gcp.secretmanager.SecretVersion("netcidr-v2-db-url", {
  secret: dbUrlSecret.id,
  secretData: dbUrl,
});

const runtimeMember = runtimeSa.email.apply((email) => `serviceAccount:${email}`);
const buildMember = buildSa.email.apply((email) => `serviceAccount:${email}`);
const iapServiceAgentMember = projectNumber.apply(
  (number) => `serviceAccount:service-${number}@gcp-sa-iap.iam.gserviceaccount.com`,
);

new gcp.projects.ServiceIdentity(
  "iap-service-agent",
  {
    project,
    service: "iap.googleapis.com",
  },
  { dependsOn: services },
);

new gcp.projects.IAMMember("netcidr-v2-runtime-cloudsql", {
  project,
  role: "roles/cloudsql.client",
  member: runtimeMember,
});

new gcp.secretmanager.SecretIamMember("netcidr-v2-runtime-db-url-secret", {
  project,
  secretId: dbUrlSecret.secretId,
  role: "roles/secretmanager.secretAccessor",
  member: runtimeMember,
});

new gcp.artifactregistry.RepositoryIamMember("netcidr-v2-build-ar-writer", {
  project,
  location: imageRepo.location,
  repository: imageRepo.repositoryId,
  role: "roles/artifactregistry.writer",
  member: buildMember,
});

new gcp.projects.IAMMember("netcidr-v2-build-run-admin", {
  project,
  role: "roles/run.admin",
  member: buildMember,
});

new gcp.serviceaccount.IAMMember("netcidr-v2-build-act-as-runtime", {
  serviceAccountId: runtimeSa.name,
  role: "roles/iam.serviceAccountUser",
  member: buildMember,
});

const targetImage = pulumi.interpolate`${region}-docker.pkg.dev/${project}/${names.artifactRepo}/${names.imageName}:latest`;
const oidcAudienceValue = pulumi.interpolate`/projects/${projectNumber}/locations/${region}/services/${names.service}`;

const cloudRunService = new gcp.cloudrunv2.Service(
  "netcidr-v2-service",
  {
    project,
    name: names.service,
    location: region,
    ingress: "INGRESS_TRAFFIC_ALL",
    launchStage: "BETA",
    iapEnabled: true,
    deletionProtection,
    labels,
    template: {
      serviceAccount: runtimeSa.email,
      timeout: "30s",
      maxInstanceRequestConcurrency: 80,
      scaling: {
        minInstanceCount: minInstances,
        maxInstanceCount: maxInstances,
      },
      volumes: [
        {
          name: "cloudsql",
          cloudSqlInstance: {
            instances: [sqlInstance.connectionName],
          },
        },
      ],
      containers: [
        {
          image: bootstrapImage,
          args: ["serve", "--address", "0.0.0.0", "--port", "8080", "--config", "/app/netcidr.toml"],
          ports: {
            containerPort: 8080,
          },
          envs: [
            {
              name: "RUST_LOG",
              value: "info",
            },
            {
              name: "NETCIDR_OIDC_AUDIENCE",
              value: oidcAudienceValue,
            },
            {
              name: "NETCIDR_IPAM_DB_URL",
              valueSource: {
                secretKeyRef: {
                  secret: dbUrlSecret.secretId,
                  version: "latest",
                },
              },
            },
          ],
          resources: {
            limits: {
              cpu: "1",
              memory: "512Mi",
            },
            cpuIdle: true,
          },
          volumeMounts: [
            {
              name: "cloudsql",
              mountPath: "/cloudsql",
            },
          ],
        },
      ],
    },
  },
  {
    dependsOn: [database, dbUser],
    ignoreChanges: ["template.containers[0].image"],
    protect: deletionProtection,
  },
);

new gcp.cloudrunv2.ServiceIamMember("netcidr-v2-iap-invoker", {
  project,
  location: cloudRunService.location,
  name: cloudRunService.name,
  role: "roles/run.invoker",
  member: iapServiceAgentMember,
});

const customDomainMapping = customDomain
  ? new gcp.cloudrun.DomainMapping(
      "netcidr-v2-domain",
      {
        project,
        location: region,
        name: customDomain,
        metadata: {
          namespace: project,
          labels,
        },
        spec: {
          routeName: cloudRunService.name,
          certificateMode: "AUTOMATIC",
        },
      },
      { dependsOn: [cloudRunService] },
    )
  : undefined;

const iapOauthClientSecret =
  iapOauthClientSecretConfig ??
  (iapOauthClientSecretSecretId
    ? pulumi
        .secret(
          gcp.secretmanager.getSecretVersionAccessOutput({
            project,
            secret: iapOauthClientSecretSecretId,
            version: iapOauthClientSecretVersion,
          }).secretData,
        )
        .apply((secret) => secret.trim())
    : undefined);

if (iapOauthClientId && iapOauthClientSecret) {
  new gcp.iap.Settings(
    "netcidr-v2-iap-oauth-settings",
    {
      name: pulumi.interpolate`projects/${projectNumber}/iap_web/cloud_run-${region}/services/${cloudRunService.name}`,
      accessSettings: {
        oauthSettings: {
          clientId: iapOauthClientId,
          clientSecret: iapOauthClientSecret,
        },
      },
    },
    { dependsOn: [cloudRunService] },
  );
} else {
  pulumi.log.info(
    "Direct Cloud Run IAP is enabled without custom OAuth credentials; IAP will use Google-managed OAuth where available. If the project needs first-time IAP initialization, complete that once in the Cloud Run Console.",
  );
}

const cloudBuildRepository = pulumi.interpolate`projects/${project}/locations/${region}/connections/${deployRepoConnection}/repositories/${deployRepoName}`;
const triggerServiceAccount = buildSa.email.apply(
  (email) => `projects/${project}/serviceAccounts/${email}`,
);

const buildTrigger = new gcp.cloudbuild.Trigger(
  "netcidr-v2-build-trigger",
  {
    project,
    location: region,
    name: names.trigger,
    description: "Pulumi-managed build and image rollout for upstream netcidr v2",
    serviceAccount: triggerServiceAccount,
    sourceToBuild: {
      repository: cloudBuildRepository,
      ref: `refs/heads/${deployRepoBranch}`,
      repoType: "GITHUB",
    },
    gitFileSource: {
      path: "cloudbuild-v2.yaml",
      repository: cloudBuildRepository,
      revision: `refs/heads/${deployRepoBranch}`,
      repoType: "GITHUB",
    },
    substitutions: {
      _REGION: region,
      _AR_REPO: names.artifactRepo,
      _IMAGE_NAME: names.imageName,
      _SERVICE_NAME: names.service,
      _NETCIDR_REF: netcidrRef,
      _FEATURES: "default,ipam-postgres",
      _WITH_DASHBOARD: "true",
    },
  },
  { dependsOn: [imageRepo, cloudRunService] },
);

export const artifactRepository = imageRepo.repositoryId;
export const image = targetImage;
export const serviceName = cloudRunService.name;
export const serviceUri = cloudRunService.uri;
export const customDomainUrl = customDomainMapping
  ? pulumi.interpolate`https://${customDomainMapping.name}`
  : undefined;
export const iapEnabled = cloudRunService.iapEnabled;
export const oidcAudience = oidcAudienceValue;
export const dbUrlSecretName = dbUrlSecret.secretId;
export const cloudSqlConnectionName = sqlInstance.connectionName;
export const buildTriggerName = buildTrigger.name;
export const runBuildTriggerCommand = pulumi.interpolate`gcloud builds triggers run ${buildTrigger.name} --region=${region} --branch=${deployRepoBranch} --project=${project}`;
