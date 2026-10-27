// Notices a netcidr release that isn't deployed yet. `check` compares the
// newest published GitHub release with what the public endpoint's /version
// reports, and decides whether that release still needs announcing;
// `acknowledge` records the announcement once it was sent, so each release
// is announced once.
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
  // pending, and not announced yet.
  needsNotify: z.boolean(),
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
        "Compare the newest published release with the deployed /version",
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

        const pending = release.tag_name !== `v${live.version}`;
        const notifiedTag = previous?.notifiedTag ?? "";
        const status: Status = {
          latestTag: release.tag_name,
          releaseUrl: release.html_url,
          publishedAt: release.published_at,
          liveVersion: live.version,
          liveCommit: live.commit,
          pending,
          notifiedTag,
          needsNotify: pending && release.tag_name !== notifiedTag,
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
      description: "Record that the pending release was announced",
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
