// Idempotent record upsert for @webframp/cloudflare/dns, which only has
// separate list/create/update. Replaces aws/cloudflare/update-dns.sh:
// create the record if missing, patch it if content/proxied/ttl drifted,
// otherwise leave it alone.
import { z } from "npm:zod@4";

const UpsertSchema = z.object({
  recordId: z.string(),
  name: z.string(),
  type: z.string(),
  content: z.string(),
  proxied: z.boolean(),
  ttl: z.number(),
  action: z.enum(["created", "updated", "unchanged"]),
  checkedAt: z.string(),
});

type Args = {
  name: string;
  type: string;
  content: string;
  proxied: boolean;
  ttl: number;
};

type CfRecord = {
  id: string;
  name: string;
  type: string;
  content: string;
  proxied: boolean;
  ttl: number;
};

type Context = {
  globalArgs: { apiToken: string; zoneId: string };
  logger: { info(msg: string, props?: Record<string, unknown>): void };
  writeResource: (
    specName: string,
    name: string,
    data: Record<string, unknown>,
  ) => Promise<{ name: string }>;
};

async function cf<T>(
  token: string,
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const res = await fetch(`https://api.cloudflare.com/client/v4${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok || !json.success) {
    throw new Error(
      `Cloudflare ${method} ${path} failed (${res.status}): ${
        JSON.stringify(json.errors)
      }`,
    );
  }
  return json.result as T;
}

export const extension = {
  type: "@webframp/cloudflare/dns",
  resources: {
    "dnsUpsert": {
      description: "Result of the last upsert: the record as it now stands",
      schema: UpsertSchema,
      lifetime: "infinite",
      garbageCollection: 20,
    },
  },
  methods: [{
    upsert: {
      description:
        "Create the record if missing, update it if content/proxied/ttl differ, otherwise no-op",
      arguments: z.object({
        name: z.string(),
        type: z.enum(["A", "AAAA", "CNAME", "TXT"]).default("CNAME"),
        content: z.string().min(1),
        // Gray cloud by default: CloudFront terminates TLS for netcidr,
        // and Cloudflare's free proxy can't rewrite Host (see CLAUDE.md).
        proxied: z.boolean().default(false),
        ttl: z.number().default(1),
      }),
      execute: async (args: Args, ctx: Context) => {
        const { apiToken, zoneId } = ctx.globalArgs;
        const base = `/zones/${zoneId}/dns_records`;
        const want = {
          type: args.type,
          name: args.name,
          content: args.content,
          proxied: args.proxied,
          ttl: args.ttl,
        };

        const existing = await cf<CfRecord[]>(
          apiToken,
          "GET",
          `${base}?type=${args.type}&name=${encodeURIComponent(args.name)}`,
        );
        if (existing.length > 1) {
          throw new Error(
            `${existing.length} ${args.type} records named ${args.name}; refusing to guess which to update`,
          );
        }

        let record: CfRecord;
        let action: "created" | "updated" | "unchanged";
        const current = existing[0];
        if (!current) {
          record = await cf<CfRecord>(apiToken, "POST", base, want);
          action = "created";
        } else if (
          current.content !== want.content ||
          current.proxied !== want.proxied ||
          current.ttl !== want.ttl
        ) {
          record = await cf<CfRecord>(
            apiToken,
            "PATCH",
            `${base}/${current.id}`,
            want,
          );
          action = "updated";
        } else {
          record = current;
          action = "unchanged";
        }

        ctx.logger.info("{name} {type} → {content}: {action}", {
          name: record.name,
          type: record.type,
          content: record.content,
          action,
        });
        const handle = await ctx.writeResource("dnsUpsert", "dnsUpsert", {
          recordId: record.id,
          name: record.name,
          type: record.type,
          content: record.content,
          proxied: record.proxied,
          ttl: record.ttl,
          action,
          checkedAt: new Date().toISOString(),
        });
        return { dataHandles: [handle] };
      },
    },
  }],
};
