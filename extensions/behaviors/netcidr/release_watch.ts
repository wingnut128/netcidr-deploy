// Announces each new netcidr release. `check` compares the newest published
// GitHub release with what the public endpoint's /version reports, decides
// whether that release still needs announcing, and words the announcement
// (already live, or still to deploy); `acknowledge` records the
// announcement once it was sent, so each release is announced once.
//
// Reads only public endpoints, so it needs no credentials and can run
// unattended. Deploying stays a manual `swamp workflow run deploy`.
import { z } from "npm:zod@4";

const GlobalArgsSchema = z.object({
  repo: z.string().describe("GitHub owner/name, e.g. wingnut128/netcidr"),
  publicUrl: z.string().describe("Deployed base URL serving /version"),
});

const StatusSchema = z.object({
  latestTag: z.string(),
  releaseUrl: z.string(),
  publishedAt: z.string(),
  liveVersion: z.string(),
  liveCommit: z.string(),
  // The newest release isn't what the endpoint serves.
  pending: z.boolean(),
  // Last release announced; carried across checks.
  notifiedTag: z.string(),
  // The newest release hasn't been announced yet, deployed or not.
  needsNotify: z.boolean(),
  // Discord announcement for latestTag.
  message: z.string(),
  checkedAt: z.string(),
});

type Status = z.infer<typeof StatusSchema>;

type Context = {
  globalArgs: z.infer<typeof GlobalArgsSchema>;
  logger: { info(msg: string, props?: Record<string, unknown>): void };
  writeResource: (
    specName: string,
    name: string,
    data: Record<string, unknown>,
  ) => Promise<{ name: string }>;
  readResource?: (name: string) => Promise<Record<string, unknown> | null>;
};

async function getJson(url: string, headers: Record<string, string> = {}) {
  const res = await fetch(url, { headers });
  if (!res.ok) {
    throw new Error(`GET ${url}: HTTP ${res.status} ${await res.text()}`);
  }
  return await res.json();
}

const DEPLOY_COMMAND = "`AWS_PROFILE=netcidr-admin swamp workflow run deploy`";

/** Whether to announce the newest release, and the announcement text. */
export function decide(
  release: { tag: string; url: string },
  liveVersion: string,
  notifiedTag: string,
): { pending: boolean; needsNotify: boolean; message: string } {
  const pending = release.tag !== `v${liveVersion}`;
  const message = pending
    ? `netcidr ${release.tag} is released but not deployed (live: v${liveVersion}). ` +
      `${release.url} — deploy from netcidr-deploy with ${DEPLOY_COMMAND}`
    : `netcidr ${release.tag} is released and already live. ${release.url}`;
  return { pending, needsNotify: release.tag !== notifiedTag, message };
}

export const model = {
  type: "@dr_evil/netcidr-release-watch",
  version: "2026.10.27.1",
  globalArguments: GlobalArgsSchema,
  resources: {
    status: {
      description: "Newest release vs. the deployed version",
      schema: StatusSchema,
      lifetime: "infinite",
      garbageCollection: 50,
    },
  },
  methods: {
    check: {
      description:
        "Compare the newest published release with the deployed /version and word its announcement",
      arguments: z.object({}),
      execute: async (_args: Record<string, never>, ctx: Context) => {
        const ga = ctx.globalArgs;
        // releases/latest skips drafts and pre-releases, so a release-plz
        // draft only counts once release.yml has published it.
        const release = await getJson(
          `https://api.github.com/repos/${ga.repo}/releases/latest`,
          {
            accept: "application/vnd.github+json",
            "x-github-api-version": "2022-11-28",
          },
        );
        const live = await getJson(`${ga.publicUrl}/version`);
        const previous = await ctx.readResource?.("status") as Status | null;

        const notifiedTag = previous?.notifiedTag ?? "";
        const decision = decide(
          { tag: release.tag_name, url: release.html_url },
          live.version,
          notifiedTag,
        );
        const status: Status = {
          latestTag: release.tag_name,
          releaseUrl: release.html_url,
          publishedAt: release.published_at,
          liveVersion: live.version,
          liveCommit: live.commit,
          notifiedTag,
          ...decision,
          checkedAt: new Date().toISOString(),
        };
        ctx.logger.info("latest {tag}, live v{live}, notify: {notify}", {
          tag: status.latestTag,
          live: status.liveVersion,
          notify: status.needsNotify,
        });
        const handle = await ctx.writeResource("status", "status", status);
        return { dataHandles: [handle] };
      },
    },
    acknowledge: {
      description: "Record that the newest release was announced",
      arguments: z.object({}),
      execute: async (_args: Record<string, never>, ctx: Context) => {
        const status = await ctx.readResource!("status") as Status | null;
        if (!status) throw new Error("No status recorded — run check first");
        const handle = await ctx.writeResource("status", "status", {
          ...status,
          notifiedTag: status.latestTag,
          needsNotify: false,
        });
        return { dataHandles: [handle] };
      },
    },
  },
};
