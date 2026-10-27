// Renders the netcidr-lambda-artifact `audit` result: what blocks a
// deploy, where each fix lives, and what is accepted and until when.
// Runs after every method of a definition that requires it; anything but
// `audit` gets a one-line no-op.

type Finding = {
  source: "cargo" | "bun" | "toolchain";
  id: string;
  package: string;
  version: string;
  severity: string;
  score: number | null;
  title: string;
  fixedIn: string;
  url: string;
  shipped: boolean;
  accepted: boolean;
  blocking: boolean;
  note: string;
};

type Audit = {
  ref: string;
  commit: string;
  auditedAt: string;
  blocking: number;
  findings: Finding[];
  toolchain: { tool: string; version: string; status: string; note: string }[];
};

type Context = {
  methodName: string;
  modelType: string;
  modelId: string;
  executionStatus: "succeeded" | "failed";
  errorMessage?: string;
  dataHandles: { name: string; specName?: string; version: number }[];
  dataRepository: {
    getContent(
      type: string,
      modelId: string,
      name: string,
      version?: number,
    ): Promise<Uint8Array | null>;
  };
};

// Where the fix for a finding has to be made.
function fixHint(f: Finding): string {
  if (f.source === "toolchain") {
    return `bump the ${f.package} pin in netcidr-deploy`;
  }
  const fix = f.fixedIn && f.fixedIn !== "see advisory"
    ? ` to ${f.fixedIn}`
    : "";
  if (f.source === "bun") {
    return `netcidr dashboard: bump ${f.package}${fix} (override if transitive)`;
  }
  return `netcidr: \`cargo update -p ${f.package}\`${fix}, or a parent bump if it's a major`;
}

const row = (cells: (string | number)[]) =>
  `| ${cells.map((c) => String(c).replaceAll("|", "\\|")).join(" | ")} |`;

export const report = {
  name: "@dr_evil/netcidr-security",
  description: "Deploy gate verdict and fix plan for the netcidr Lambda audit",
  scope: "method",
  labels: ["security", "netcidr"],
  execute: async (context: Context) => {
    if (context.methodName !== "audit") {
      return { markdown: "", json: { skipped: true } };
    }
    if (context.executionStatus === "failed") {
      return {
        markdown: `# netcidr security audit — FAILED TO RUN\n\n${
          context.errorMessage ?? ""
        }\n`,
        json: { ran: false, error: context.errorMessage ?? "" },
      };
    }

    const handle = context.dataHandles.find((h) => h.name === "audit");
    const raw = handle &&
      await context.dataRepository.getContent(
        context.modelType,
        context.modelId,
        handle.name,
        handle.version,
      );
    if (!raw) {
      return { markdown: "No audit data produced.", json: { ran: false } };
    }
    const audit = JSON.parse(new TextDecoder().decode(raw)) as Audit;

    const blocking = audit.findings.filter((f) => f.blocking);
    const accepted = audit.findings.filter((f) => f.accepted);
    const info = audit.findings.filter((f) => !f.blocking && !f.accepted);

    const lines = [
      `# netcidr security audit — ${audit.ref} (${audit.commit.slice(0, 8)})`,
      "",
      blocking.length
        ? `**Deploy gate: BLOCKED** by ${blocking.length} finding(s).`
        : "**Deploy gate: PASS.**",
      "",
    ];

    if (blocking.length) {
      lines.push(
        "## Blocking — fix before deploying",
        "",
        row(["Advisory", "Package", "Severity", "Fix"]),
        row(["---", "---", "---", "---"]),
        ...blocking.map((f) =>
          row([
            `[${f.id}](${f.url})`,
            `${f.package} ${f.version}`,
            f.severity,
            fixHint(f),
          ])
        ),
        "",
      );
    }
    if (accepted.length) {
      lines.push(
        "## Accepted",
        "",
        row(["Advisory", "Package", "Ships", "Basis"]),
        row(["---", "---", "---", "---"]),
        ...accepted.map((f) =>
          row([
            `[${f.id}](${f.url})`,
            `${f.package} ${f.version}`,
            f.shipped ? "yes" : "no",
            f.note,
          ])
        ),
        "",
      );
    }
    if (info.length) {
      lines.push(
        "## Informational — not gating",
        "",
        "Not in the Lambda binary, or below the gate's severity threshold.",
        "",
        row(["Advisory", "Package", "Severity", "Ships", "Fix"]),
        row(["---", "---", "---", "---", "---"]),
        ...info.map((f) =>
          row([
            `[${f.id}](${f.url})`,
            `${f.package} ${f.version}`,
            f.severity,
            f.shipped ? "yes" : "no",
            fixHint(f),
          ])
        ),
        "",
      );
    }
    lines.push(
      "## Toolchain",
      "",
      row(["Tool", "Version", "Status", "Note"]),
      row(["---", "---", "---", "---"]),
      ...audit.toolchain.map((t) => row([t.tool, t.version, t.status, t.note])),
      "",
      "Pins move only for a security fix or a real compatibility break, never just because a newer release exists.",
    );

    return {
      markdown: lines.join("\n"),
      json: {
        ref: audit.ref,
        commit: audit.commit,
        gate: blocking.length ? "blocked" : "pass",
        blocking: blocking.map((f) => ({
          id: f.id,
          package: f.package,
          fix: fixHint(f),
        })),
        accepted: accepted.map((f) => ({
          id: f.id,
          package: f.package,
          basis: f.note,
        })),
        informational: info.length,
      },
    };
  },
};
