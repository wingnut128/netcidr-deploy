// Builds the netcidr Lambda binary from a release tag of a local netcidr
// clone. Mirrors the build half of .github/workflows/deploy.yml:
//   dashboard SPA (bun) → cargo lambda build (arm64 gnu, glibc 2.28 floor)
//
// Builds run in a dedicated git worktree under `workDir`, never in the
// netcidr working copy, so uncommitted changes can't ship under a tag.
// The cargo target dir lives beside it so incremental builds stay warm.
//
// Toolchain versions are checked, not installed. CI pins Zig 0.13.0 and
// cargo-lambda 1.9.2 for reasons recorded in deploy.yml; a mismatch
// fails the build before any compile starts.
import { z } from "npm:zod@4";
import { parse as parseYaml } from "npm:yaml@2.9.1";
import {
  HeadObjectCommand,
  NotFound,
  PutObjectCommand,
  S3Client,
} from "npm:@aws-sdk/client-s3@3.1150.0";

const GlobalArgs = z.object({
  netcidrDir: z.string().describe(
    "Local netcidr clone. Tags are fetched here; the build itself runs in a separate worktree.",
  ),
  workDir: z.string().describe(
    "Holds the build worktree (src/) and the cargo target cache (target/).",
  ),
  oauthWebClientId: z.string().meta({ sensitive: true }).describe(
    "Google OAuth Web Client ID, baked into the dashboard as VITE_OAUTH_WEB_CLIENT_ID.",
  ),
  zigPath: z.string().default("zig").describe(
    "Zig binary handed to cargo-zigbuild via CARGO_ZIGBUILD_ZIG_PATH.",
  ),
  zigVersion: z.string().default("0.13.0"),
  cargoLambdaVersion: z.string().default("1.9.2"),
  // Explicit glibc floor rather than --arm64, which leaves it to Zig's
  // default and so varies by Zig release. AL2023 ships glibc 2.34.
  target: z.string().default("aarch64-unknown-linux-gnu.2.28"),
  features: z.string().default("lambda,ipam-postgres"),
  templatePath: z.string().describe(
    "SAM template whose AWS::Serverless::Function CodeUri gets pointed at the uploaded zip.",
  ).optional(),
  artifactBucket: z.string().describe(
    "S3 bucket for Lambda zips (SAM's managed source bucket).",
  ).optional(),
  region: z.string().optional(),
  publicUrl: z.string().describe(
    "Public base URL; its /version endpoint reports the live commit.",
  ).optional(),
  // Deploy-side risk acceptances, reviewed in git like netcidr's own
  // deny.toml ignores (which the audit also honours). An expired entry
  // stops counting, so acceptances get revisited instead of rotting.
  acceptedAdvisories: z.array(z.object({
    id: z.string(),
    reason: z.string(),
    expires: z.string().describe("YYYY-MM-DD"),
  })).default([]),
});

type Args = z.infer<typeof GlobalArgs>;

const BuildSchema = z.object({
  ref: z.string(),
  commit: z.string(),
  sha256: z.string(),
  sizeBytes: z.number(),
  target: z.string(),
  zigVersion: z.string(),
  cargoLambdaVersion: z.string(),
  rustcVersion: z.string(),
  builtAt: z.string(),
});

const FindingSchema = z.object({
  source: z.enum(["cargo", "bun", "toolchain"]),
  id: z.string(),
  package: z.string(),
  version: z.string(),
  severity: z.enum(["critical", "high", "medium", "low", "unknown"]),
  score: z.number().nullable(),
  title: z.string(),
  fixedIn: z.string(),
  url: z.string(),
  // In the Lambda's normal dependency graph for the built target and
  // features — as opposed to dev/build-only crates in the lockfile.
  shipped: z.boolean(),
  accepted: z.boolean(),
  blocking: z.boolean(),
  note: z.string(),
});

const AuditSchema = z.object({
  ref: z.string(),
  commit: z.string(),
  auditedAt: z.string(),
  blocking: z.number(),
  findings: z.array(FindingSchema),
  toolchain: z.array(z.object({
    tool: z.string(),
    version: z.string(),
    status: z.enum(["ok", "advisory", "no-feed"]),
    note: z.string(),
  })),
});

type Finding = z.infer<typeof FindingSchema>;

const PackageSchema = z.object({
  ref: z.string(),
  commit: z.string(),
  sha256: z.string(),
  bucket: z.string(),
  key: z.string(),
  uploaded: z.boolean().describe("false when the zip was already in S3"),
  // The SAM template as JSON, CodeUri rewritten to the S3 object. Fed to
  // the stack behavior's TemplateBody.
  body: z.record(z.string(), z.unknown()),
});

const LiveSchema = z.object({
  url: z.string(),
  version: z.string(),
  commit: z.string(),
  checkedAt: z.string(),
});

type Logger = {
  info(msg: string, props?: Record<string, unknown>): void;
};

type Context = {
  globalArgs: Args;
  logger: Logger;
  writeResource: (
    specName: string,
    name: string,
    data: Record<string, unknown>,
  ) => Promise<{ name: string }>;
  createFileWriter: (
    specName: string,
    name: string,
  ) => { writeAll(content: Uint8Array): Promise<{ name: string }> };
  readResource?: (name: string) => Promise<Record<string, unknown> | null>;
  modelType: string;
  modelId: string;
  dataRepository: {
    getContent(
      type: string,
      modelId: string,
      name: string,
    ): Promise<Uint8Array | null>;
  };
};

// Runs a command, streaming each output line to the swamp run log, and
// returns trimmed stdout. Throws on a non-zero exit.
async function run(
  logger: Logger,
  cmd: string,
  args: string[],
  opts: {
    cwd?: string;
    env?: Record<string, string>;
    // Audit tools exit non-zero when they find something; their JSON is
    // still the result we want.
    allowFailure?: boolean;
    quiet?: boolean;
  } = {},
): Promise<string> {
  logger.info("$ {cmd}", { cmd: [cmd, ...args].join(" ") });
  const child = new Deno.Command(cmd, {
    args,
    cwd: opts.cwd,
    env: opts.env,
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  const pump = async (stream: ReadableStream<Uint8Array>) => {
    const lines: string[] = [];
    let buf = "";
    for await (const chunk of stream.pipeThrough(new TextDecoderStream())) {
      buf += chunk;
      const parts = buf.split("\n");
      buf = parts.pop() ?? "";
      for (const line of parts) {
        lines.push(line);
        if (!opts.quiet) logger.info("{line}", { line });
      }
    }
    if (buf) {
      lines.push(buf);
      if (!opts.quiet) logger.info("{line}", { line: buf });
    }
    return lines.join("\n");
  };

  const [stdout, stderr, status] = await Promise.all([
    pump(child.stdout),
    pump(child.stderr),
    child.status,
  ]);
  if (!status.success && !opts.allowFailure) {
    const tail = stderr.split("\n").slice(-20).join("\n");
    throw new Error(`${cmd} ${args.join(" ")} exited ${status.code}\n${tail}`);
  }
  return stdout.trim();
}

async function exists(path: string): Promise<boolean> {
  try {
    await Deno.stat(path);
    return true;
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return false;
    throw e;
  }
}

async function checkToolchain(ctx: Context) {
  const { zigPath, zigVersion, cargoLambdaVersion } = ctx.globalArgs;
  const zig = await run(ctx.logger, zigPath, ["version"]);
  if (zig !== zigVersion) {
    throw new Error(
      `Zig at ${zigPath} is ${zig}, expected ${zigVersion}. Point zigPath at a ${zigVersion} install.`,
    );
  }
  const cl = await run(ctx.logger, "cargo", ["lambda", "--version"]);
  // "cargo-lambda 1.9.2 (2026-…)"
  if (cl.split(/\s+/)[1] !== cargoLambdaVersion) {
    throw new Error(
      `${cl} is installed, expected cargo-lambda ${cargoLambdaVersion}.`,
    );
  }
  const rustc = await run(ctx.logger, "rustc", ["--version"]);
  return { zig, cargoLambda: cargoLambdaVersion, rustc };
}

// Newest v* tag when no ref is given; otherwise a tag, then an
// origin branch, then anything git can resolve (e.g. a SHA).
async function resolveRef(ctx: Context, ref: string | undefined) {
  const git = (...a: string[]) =>
    run(ctx.logger, "git", ["-C", ctx.globalArgs.netcidrDir, ...a]);
  await git("fetch", "--tags", "origin");

  const name = ref ??
    (await git("tag", "--list", "v*", "--sort=-v:refname")).split("\n")[0];
  if (!name) throw new Error("No v* tags found in netcidr clone");

  for (
    const candidate of [
      `refs/tags/${name}`,
      `refs/remotes/origin/${name}`,
      name,
    ]
  ) {
    try {
      const commit = await git(
        "rev-parse",
        "--verify",
        `${candidate}^{commit}`,
      );
      return { name, commit };
    } catch {
      // try the next form
    }
  }
  throw new Error(`Cannot resolve netcidr ref "${name}"`);
}

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// CloudFormation short-form tags (!Ref, !GetAtt a.b, !If [...]) mapped to
// their JSON long forms, in scalar, sequence and mapping positions.
// Composition is bottom-up, so nested tags are already resolved when an
// outer collection's toJSON() runs.
const CFN_FUNCTIONS = [
  "And",
  "Base64",
  "Cidr",
  "Equals",
  "FindInMap",
  "GetAZs",
  "GetAtt",
  "If",
  "ImportValue",
  "Join",
  "Not",
  "Or",
  "Select",
  "Split",
  "Sub",
  "Transform",
];

function cfnTags() {
  const tags = [];
  for (const name of [...CFN_FUNCTIONS, "Ref", "Condition"]) {
    const key = name === "Ref" || name === "Condition" ? name : `Fn::${name}`;
    tags.push({
      tag: `!${name}`,
      resolve: (v: string) => {
        if (name !== "GetAtt") return { [key]: v };
        const dot = v.indexOf(".");
        return { [key]: [v.slice(0, dot), v.slice(dot + 1)] };
      },
    });
    for (const collection of ["seq", "map"] as const) {
      tags.push({
        tag: `!${name}`,
        collection,
        resolve: (node: { toJSON(): unknown }) => ({ [key]: node.toJSON() }),
      });
    }
  }
  return tags;
}

export function parseCfnYaml(text: string): Record<string, unknown> {
  // yaml's Tag types are wider than these plain objects need to be.
  return parseYaml(text, { customTags: cfnTags() as never }) as Record<
    string,
    unknown
  >;
}

// CVSS v3.x base score (FIRST spec §7.1). Returns null for anything else
// (v4 vectors, malformed input), which the gate treats as unknown.
function cvss3Score(vector: string | null | undefined): number | null {
  if (!vector?.startsWith("CVSS:3.")) return null;
  const m = Object.fromEntries(
    vector.split("/").slice(1).map((kv) => kv.split(":") as [string, string]),
  );
  const changed = m.S === "C";
  const w: Record<string, Record<string, number>> = {
    AV: { N: 0.85, A: 0.62, L: 0.55, P: 0.2 },
    AC: { L: 0.77, H: 0.44 },
    PR: changed ? { N: 0.85, L: 0.68, H: 0.5 } : { N: 0.85, L: 0.62, H: 0.27 },
    UI: { N: 0.85, R: 0.62 },
    CIA: { H: 0.56, L: 0.22, N: 0 },
  };
  const get = (k: string, table = k) => w[table]?.[m[k]];
  const vals = [
    get("AV"),
    get("AC"),
    get("PR"),
    get("UI"),
    get("C", "CIA"),
    get("I", "CIA"),
    get("A", "CIA"),
  ];
  if (vals.some((v) => v === undefined)) return null;
  const [av, ac, pr, ui, c, i, a] = vals as number[];

  const iss = 1 - (1 - c) * (1 - i) * (1 - a);
  const impact = changed
    ? 7.52 * (iss - 0.029) - 3.25 * Math.pow(iss - 0.02, 15)
    : 6.42 * iss;
  if (impact <= 0) return 0;
  const exploitability = 8.22 * av * ac * pr * ui;
  const raw = changed
    ? Math.min(1.08 * (impact + exploitability), 10)
    : Math.min(impact + exploitability, 10);
  const n = Math.round(raw * 100000);
  return n % 10000 === 0 ? n / 100000 : (Math.floor(n / 10000) + 1) / 10;
}

function severityOf(score: number | null): Finding["severity"] {
  if (score === null) return "unknown";
  if (score >= 9) return "critical";
  if (score >= 7) return "high";
  if (score >= 4) return "medium";
  return "low";
}

// RUSTSEC ids from netcidr's deny.toml [advisories] ignore list — the
// upstream repo's own documented acceptances.
async function denyIgnores(src: string): Promise<string[]> {
  let toml: string;
  try {
    toml = await Deno.readTextFile(`${src}/deny.toml`);
  } catch {
    return [];
  }
  const section = toml.split(/^\[advisories\]/m)[1]?.split(/^\[/m)[0] ?? "";
  const ignore = section.match(/ignore\s*=\s*\[([\s\S]*?)\]/)?.[1] ?? "";
  // Strip comments before matching so ids mentioned in prose don't count.
  const code = ignore.split("\n").map((l) => l.replace(/#.*/, "")).join("\n");
  return [...code.matchAll(/"(RUSTSEC-\d{4}-\d{4})"/g)].map((x) => x[1]);
}

export const behavior = {
  type: "@dr_evil/netcidr-lambda-artifact",
  version: "2026.10.27.1",
  globalArguments: GlobalArgs,
  resources: {
    "build": {
      description: "Provenance of the latest Lambda binary build",
      schema: BuildSchema,
      lifetime: "infinite",
      garbageCollection: 20,
    },
    "audit": {
      description:
        "Security findings for the last build and whether they block a deploy",
      schema: AuditSchema,
      lifetime: "infinite",
      garbageCollection: 20,
    },
    "package": {
      description: "Uploaded Lambda zip and the deployable template body",
      schema: PackageSchema,
      lifetime: "infinite",
      garbageCollection: 20,
    },
    "live": {
      description: "Version and commit the public endpoint reports",
      schema: LiveSchema,
      lifetime: "infinite",
      garbageCollection: 50,
    },
  },
  files: {
    "bootstrap": {
      description: "The Lambda bootstrap binary (arm64 gnu)",
      contentType: "application/octet-stream",
      lifetime: "infinite",
      garbageCollection: 5,
    },
  },
  methods: {
    build: {
      description:
        "Fetch tags, check out a netcidr ref in a clean worktree, build the dashboard and Lambda binary",
      arguments: z.object({
        ref: z.string().optional().describe(
          "netcidr tag, branch or SHA. Defaults to the newest v* tag.",
        ),
      }),
      execute: async (args: { ref?: string }, ctx: Context) => {
        const ga = ctx.globalArgs;
        const tools = await checkToolchain(ctx);
        // Workflows pass "" for "no ref given".
        const ref = await resolveRef(ctx, args.ref || undefined);
        ctx.logger.info("Building netcidr {name} ({commit})", ref);

        const src = `${ga.workDir}/src`;
        const targetDir = `${ga.workDir}/target`;
        if (await exists(src)) {
          await run(ctx.logger, "git", [
            "-C",
            src,
            "checkout",
            "--detach",
            "--force",
            ref.commit,
          ]);
          await run(ctx.logger, "git", ["-C", src, "clean", "-ffdx"]);
        } else {
          await Deno.mkdir(ga.workDir, { recursive: true });
          await run(ctx.logger, "git", [
            "-C",
            ga.netcidrDir,
            "worktree",
            "add",
            "--detach",
            src,
            ref.commit,
          ]);
        }

        // Vite bakes the client ID into the bundle; without it the
        // dashboard treats auth as disabled.
        const dashboard = `${src}/dashboard`;
        await run(ctx.logger, "bun", ["install", "--frozen-lockfile"], {
          cwd: dashboard,
        });
        await run(ctx.logger, "bun", ["run", "build"], {
          cwd: dashboard,
          env: { VITE_OAUTH_WEB_CLIENT_ID: ga.oauthWebClientId },
        });

        await run(ctx.logger, "cargo", [
          "lambda",
          "build",
          "--release",
          "--target",
          ga.target,
          "--bin",
          "lambda",
          "--features",
          "lambda,ipam-postgres",
        ], {
          cwd: src,
          env: {
            CARGO_TARGET_DIR: targetDir,
            CARGO_ZIGBUILD_ZIG_PATH: ga.zigPath,
          },
        });

        const bytes = await Deno.readFile(
          `${targetDir}/lambda/lambda/bootstrap`,
        );
        const sha256 = await sha256Hex(bytes);
        const fileHandle = await ctx.createFileWriter("bootstrap", "bootstrap")
          .writeAll(bytes);
        const buildHandle = await ctx.writeResource("build", "build", {
          ref: ref.name,
          commit: ref.commit,
          sha256,
          sizeBytes: bytes.length,
          target: ga.target,
          zigVersion: tools.zig,
          cargoLambdaVersion: tools.cargoLambda,
          rustcVersion: tools.rustc,
          builtAt: new Date().toISOString(),
        });
        ctx.logger.info("bootstrap {sha256} ({size} bytes)", {
          sha256,
          size: bytes.length,
        });
        return { dataHandles: [fileHandle, buildHandle] };
      },
    },
    audit: {
      description:
        "Audit the last build's commit: RustSec advisories (cargo-audit), dashboard npm advisories (bun audit), and toolchain pins (OSV). Records findings and how many block a deploy.",
      arguments: z.object({}),
      execute: async (_args: Record<string, never>, ctx: Context) => {
        const ga = ctx.globalArgs;
        const build = await ctx.readResource!("build") as
          | z.infer<typeof BuildSchema>
          | null;
        if (!build) {
          throw new Error("No build recorded — run the build method first");
        }

        const src = `${ga.workDir}/src`;
        const head = await run(ctx.logger, "git", [
          "-C",
          src,
          "rev-parse",
          "HEAD",
        ]);
        if (head !== build.commit) {
          throw new Error(
            `Worktree is at ${head}, but the last build was ${build.commit}. Rebuild before auditing.`,
          );
        }

        const today = new Date().toISOString().slice(0, 10);
        const accepted = new Map(
          ga.acceptedAdvisories
            .filter((a) => a.expires >= today)
            .map((a) => [a.id, a.reason]),
        );
        for (
          const a of ga.acceptedAdvisories.filter((a) => a.expires < today)
        ) {
          ctx.logger.info(
            "Acceptance for {id} expired {expires}; it counts again",
            a,
          );
        }
        const upstreamIgnores = await denyIgnores(src);
        for (const id of upstreamIgnores) {
          if (!accepted.has(id)) accepted.set(id, "netcidr deny.toml ignore");
        }

        // Crates in the Lambda's normal (non-dev, non-build) graph for the
        // exact target and features we ship.
        const tree = await run(ctx.logger, "cargo", [
          "tree",
          "-q",
          "--target",
          ga.target.replace(/\.\d+\.\d+$/, ""),
          "--features",
          ga.features,
          "-e",
          "normal",
          "--prefix",
          "none",
        ], { cwd: src, quiet: true });
        const shippedSet = new Set(
          tree.split("\n").map((l) => l.split(" ").slice(0, 2).join(" ")),
        );

        const findings: Finding[] = [];
        const add = (
          f: Omit<Finding, "accepted" | "blocking" | "note"> & {
            note?: string;
          },
        ) => {
          const reason = accepted.get(f.id);
          const gated = f.source === "bun"
            ? f.severity === "high" || f.severity === "critical"
            : f.shipped &&
              (f.severity === "high" || f.severity === "critical" ||
                f.severity === "unknown");
          findings.push({
            ...f,
            accepted: reason !== undefined,
            blocking: gated && reason === undefined,
            note: reason ?? f.note ?? "",
          });
        };

        // RustSec. Run from workDir, not src: cargo-audit reads the repo's
        // .cargo/audit.toml from its cwd and silently drops ignored ids.
        // Accepted findings should stay in the record, just non-blocking.
        const auditJson = JSON.parse(
          await run(
            ctx.logger,
            "cargo",
            ["audit", "--json", "--file", `${src}/Cargo.lock`],
            { cwd: ga.workDir, allowFailure: true, quiet: true },
          ),
        );
        for (const v of auditJson.vulnerabilities?.list ?? []) {
          const score = cvss3Score(v.advisory.cvss);
          add({
            source: "cargo",
            id: v.advisory.id,
            package: v.package.name,
            version: v.package.version,
            severity: severityOf(score),
            score,
            title: v.advisory.title,
            fixedIn: (v.versions.patched ?? []).join(", ") || "no fix released",
            url: v.advisory.url ??
              `https://rustsec.org/advisories/${v.advisory.id}`,
            shipped: shippedSet.has(`${v.package.name} v${v.package.version}`),
          });
        }

        // Dashboard. The whole lockfile counts: devDependencies like Vite
        // execute on this machine at build time even though only the
        // bundle ships.
        const bunOut = await run(
          ctx.logger,
          "bun",
          ["audit", "--json"],
          { cwd: `${src}/dashboard`, allowFailure: true, quiet: true },
        );
        const bunJson = bunOut ? JSON.parse(bunOut) : {};
        for (const [pkg, advisories] of Object.entries(bunJson)) {
          for (
            const a of advisories as Array<{
              id: number;
              url?: string;
              title?: string;
              severity?: string;
              vulnerable_versions?: string;
              cvss?: { score?: number };
            }>
          ) {
            const sev = FindingSchema.shape.severity.safeParse(
              a.severity === "moderate" ? "medium" : a.severity,
            );
            add({
              source: "bun",
              id: a.url?.split("/").pop() ?? String(a.id),
              package: pkg,
              version: a.vulnerable_versions ?? "",
              severity: sev.success ? sev.data : "unknown",
              score: a.cvss?.score ?? null,
              title: a.title ?? "",
              fixedIn: "see advisory",
              url: a.url ?? "",
              shipped: false,
            });
          }
        }

        // Toolchain. Only cargo-lambda has an advisory feed (OSV,
        // crates.io). Zig and rustc have none to query; that's recorded
        // rather than silently passed.
        const toolchain: z.infer<typeof AuditSchema>["toolchain"] = [];
        const osv = await fetch("https://api.osv.dev/v1/query", {
          method: "POST",
          body: JSON.stringify({
            package: { name: "cargo-lambda", ecosystem: "crates.io" },
            version: build.cargoLambdaVersion,
          }),
        }).then((r) => r.json());
        const vulns: Array<{ id: string; summary?: string }> = osv.vulns ?? [];
        toolchain.push({
          tool: "cargo-lambda",
          version: build.cargoLambdaVersion,
          status: vulns.length ? "advisory" : "ok",
          note: vulns.map((v) => v.id).join(", "),
        });
        for (const v of vulns) {
          add({
            source: "toolchain",
            id: v.id,
            package: "cargo-lambda",
            version: build.cargoLambdaVersion,
            severity: "unknown",
            score: null,
            title: v.summary ?? "",
            fixedIn: "see advisory",
            url: `https://osv.dev/vulnerability/${v.id}`,
            shipped: true,
          });
        }
        toolchain.push(
          {
            tool: "zig",
            version: build.zigVersion,
            status: "no-feed",
            note:
              "No advisory database covers Zig; pin changes stay compatibility-driven (see deploy.yml)",
          },
          {
            tool: "rustc",
            version: build.rustcVersion,
            status: "no-feed",
            note:
              "Rust toolchain advisories are published as blog posts, not a queryable feed",
          },
        );

        const blocking = findings.filter((f) => f.blocking).length;
        const handle = await ctx.writeResource("audit", "audit", {
          ref: build.ref,
          commit: build.commit,
          auditedAt: new Date().toISOString(),
          blocking,
          findings,
          toolchain,
        });
        ctx.logger.info("{n} findings, {blocking} blocking", {
          n: findings.length,
          blocking,
        });
        return { dataHandles: [handle] };
      },
    },
    package: {
      description:
        "Zip the last build's bootstrap, upload it to S3 (content-addressed, skipped if present), and render the SAM template as JSON with CodeUri pointing at it",
      arguments: z.object({}),
      execute: async (_args: Record<string, never>, ctx: Context) => {
        const ga = ctx.globalArgs;
        if (!ga.templatePath || !ga.artifactBucket || !ga.region) {
          throw new Error(
            "package needs templatePath, artifactBucket and region",
          );
        }
        const build = await ctx.readResource!("build") as
          | z.infer<typeof BuildSchema>
          | null;
        if (!build) throw new Error("No build recorded — run build first");

        const bytes = await ctx.dataRepository.getContent(
          ctx.modelType,
          ctx.modelId,
          "bootstrap",
        );
        if (!bytes) {
          throw new Error("No bootstrap binary stored — run build first");
        }
        const sha256 = await sha256Hex(new Uint8Array(bytes));
        if (sha256 !== build.sha256) {
          throw new Error(
            `Stored bootstrap is ${sha256}, but the build record says ${build.sha256}`,
          );
        }

        // Keyed by the binary's hash, so re-packaging the same build is a
        // no-op and a key always means one exact binary.
        const key = `netcidr/${sha256}.zip`;
        const s3 = new S3Client({ region: ga.region });
        let uploaded = false;
        try {
          await s3.send(
            new HeadObjectCommand({ Bucket: ga.artifactBucket, Key: key }),
          );
          ctx.logger.info("s3://{bucket}/{key} already present", {
            bucket: ga.artifactBucket,
            key,
          });
        } catch (e) {
          if (!(e instanceof NotFound)) throw e;
          const dir = await Deno.makeTempDir();
          try {
            await Deno.writeFile(`${dir}/bootstrap`, bytes, { mode: 0o755 });
            await run(ctx.logger, "zip", [
              "-X",
              "-j",
              `${dir}/lambda.zip`,
              `${dir}/bootstrap`,
            ]);
            await s3.send(
              new PutObjectCommand({
                Bucket: ga.artifactBucket,
                Key: key,
                Body: await Deno.readFile(`${dir}/lambda.zip`),
                ContentType: "application/zip",
                Metadata: {
                  "bootstrap-sha256": sha256,
                  "netcidr-ref": build.ref,
                },
              }),
            );
            uploaded = true;
            ctx.logger.info("Uploaded s3://{bucket}/{key}", {
              bucket: ga.artifactBucket,
              key,
            });
          } finally {
            await Deno.remove(dir, { recursive: true });
          }
        }

        const body = parseCfnYaml(await Deno.readTextFile(ga.templatePath));
        const resources = body.Resources as Record<
          string,
          {
            Type: string;
            Properties?: Record<string, unknown>;
            Metadata?: Record<string, unknown>;
          }
        >;
        // `sam build` stamps every resource with its logical id; matching it
        // keeps change sets free of Metadata-only diffs against SAM deploys.
        for (const [id, r] of Object.entries(resources)) {
          r.Metadata = { SamResourceId: id, ...r.Metadata };
        }
        const functions = Object.entries(resources)
          .filter(([, r]) => r.Type === "AWS::Serverless::Function");
        if (functions.length !== 1) {
          throw new Error(
            `Expected one AWS::Serverless::Function, found ${functions.length}`,
          );
        }
        functions[0][1].Properties!.CodeUri = {
          Bucket: ga.artifactBucket,
          Key: key,
        };

        const handle = await ctx.writeResource("package", "package", {
          ref: build.ref,
          commit: build.commit,
          sha256,
          bucket: ga.artifactBucket,
          key,
          uploaded,
          body,
        });
        return { dataHandles: [handle] };
      },
    },
    live: {
      description:
        "Read the version and commit the public endpoint serves; optionally wait until it reports an expected commit",
      arguments: z.object({
        expectCommit: z.string().optional(),
        waitSeconds: z.number().default(0),
      }),
      execute: async (
        args: { expectCommit?: string; waitSeconds: number },
        ctx: Context,
      ) => {
        const url = `${ctx.globalArgs.publicUrl}/version`;
        const deadline = Date.now() + args.waitSeconds * 1000;
        let body: { version: string; commit_full: string };
        while (true) {
          const res = await fetch(url, {
            headers: { "cache-control": "no-cache" },
          });
          if (!res.ok) throw new Error(`${url} returned ${res.status}`);
          body = await res.json();
          if (!args.expectCommit || body.commit_full === args.expectCommit) {
            break;
          }
          if (Date.now() >= deadline) break;
          ctx.logger.info("Live is {commit}, waiting for {expect}", {
            commit: body.commit_full,
            expect: args.expectCommit,
          });
          await new Promise((r) => setTimeout(r, 10_000));
        }
        const handle = await ctx.writeResource("live", "live", {
          url,
          version: body.version,
          commit: body.commit_full,
          checkedAt: new Date().toISOString(),
        });
        return { dataHandles: [handle] };
      },
    },
  },
};
