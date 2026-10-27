// Change-set deploys for @swamp/aws/cloudformation/stack: `plan` creates a
// change set from the behavior's own global arguments and records what it
// would change; `apply` executes exactly that change set and waits for the
// stack to settle. This is the flow `sam deploy` uses, split so a workflow
// can put an approval gate between the two.
//
// The stack type's own `update` goes through Cloud Control with no preview,
// and the change-set type has no Parameters field, hence the extension.
//
// Parameter values (vault-resolved secrets among them) are sent to
// CloudFormation and never written to swamp data: only resource-level
// changes are recorded.
import { z } from "npm:zod@4";
import {
  CloudFormationClient,
  CreateChangeSetCommand,
  DeleteChangeSetCommand,
  DescribeChangeSetCommand,
  DescribeStacksCommand,
  ExecuteChangeSetCommand,
} from "npm:@aws-sdk/client-cloudformation@3.1150.0";

const ChangeSetSchema = z.object({
  stackName: z.string(),
  changeSetName: z.string(),
  changeSetId: z.string(),
  // "ready": has changes, executable. "empty": nothing to change (deleted).
  // "applied": executed and the stack settled successfully.
  status: z.enum(["ready", "empty", "applied"]),
  changeCount: z.number(),
  changes: z.array(z.object({
    action: z.string(),
    logicalId: z.string(),
    resourceType: z.string(),
    replacement: z.string(),
    scope: z.array(z.string()),
  })),
  summary: z.string(),
  stackStatus: z.string().optional(),
  createdAt: z.string(),
  appliedAt: z.string().optional(),
});

type ChangeSet = z.infer<typeof ChangeSetSchema>;

type StackArgs = {
  region?: string;
  StackName: string;
  TemplateBody?: Record<string, unknown>;
  Parameters?: Record<string, string>;
  Capabilities?: string[];
};

type Context = {
  globalArgs: StackArgs;
  logger: { info(msg: string, props?: Record<string, unknown>): void };
  writeResource: (
    specName: string,
    name: string,
    data: Record<string, unknown>,
  ) => Promise<{ name: string }>;
  readResource?: (name: string) => Promise<Record<string, unknown> | null>;
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function client(ga: StackArgs) {
  return new CloudFormationClient({ region: ga.region });
}

export const extension = {
  type: "@swamp/aws/cloudformation/stack",
  resources: {
    "changeSet": {
      description: "Latest planned or applied change set for this stack",
      schema: ChangeSetSchema,
      lifetime: "infinite",
      garbageCollection: 20,
    },
  },
  methods: [{
    plan: {
      description:
        "Create a change set from TemplateBody/Parameters/Capabilities and record the resource changes it would make",
      arguments: z.object({}),
      execute: async (_args: Record<string, never>, ctx: Context) => {
        const ga = ctx.globalArgs;
        if (!ga.TemplateBody) throw new Error("plan needs TemplateBody");
        const cfn = client(ga);
        // Don't leave the superseded plan pending on the stack.
        const previous = await ctx.readResource?.("changeSet") as
          | ChangeSet
          | null;
        if (previous?.status === "ready") {
          await cfn.send(
            new DeleteChangeSetCommand({ ChangeSetName: previous.changeSetId }),
          ).catch(() => {}); // already executed or deleted
        }
        const changeSetName = `swamp-${
          new Date().toISOString().replace(/[:.]/g, "-")
        }`;

        const created = await cfn.send(
          new CreateChangeSetCommand({
            StackName: ga.StackName,
            ChangeSetName: changeSetName,
            ChangeSetType: "UPDATE",
            TemplateBody: JSON.stringify(ga.TemplateBody),
            Parameters: Object.entries(ga.Parameters ?? {}).map((
              [ParameterKey, ParameterValue],
            ) => ({ ParameterKey, ParameterValue })),
            Capabilities: ga.Capabilities as never,
          }),
        );
        const changeSetId = created.Id!;

        let desc;
        while (true) {
          desc = await cfn.send(
            new DescribeChangeSetCommand({ ChangeSetName: changeSetId }),
          );
          if (
            desc.Status !== "CREATE_PENDING" &&
            desc.Status !== "CREATE_IN_PROGRESS"
          ) break;
          await sleep(3000);
        }

        const record: ChangeSet = {
          stackName: ga.StackName,
          changeSetName,
          changeSetId,
          status: "ready",
          changeCount: 0,
          changes: [],
          summary: "",
          createdAt: new Date().toISOString(),
        };

        if (desc.Status === "FAILED") {
          // CloudFormation reports "no changes" as a failed change set.
          if (
            /didn't contain changes|No updates are to be performed/.test(
              desc.StatusReason ?? "",
            )
          ) {
            await cfn.send(
              new DeleteChangeSetCommand({ ChangeSetName: changeSetId }),
            );
            record.status = "empty";
            record.summary = "No changes";
          } else {
            throw new Error(`Change set failed: ${desc.StatusReason}`);
          }
        } else {
          // A change set can page its Changes; follow NextToken.
          const changes = [...(desc.Changes ?? [])];
          let next = desc.NextToken;
          while (next) {
            const page = await cfn.send(
              new DescribeChangeSetCommand({
                ChangeSetName: changeSetId,
                NextToken: next,
              }),
            );
            changes.push(...(page.Changes ?? []));
            next = page.NextToken;
          }
          record.changes = changes.map((c) => ({
            action: c.ResourceChange?.Action ?? "",
            logicalId: c.ResourceChange?.LogicalResourceId ?? "",
            resourceType: c.ResourceChange?.ResourceType ?? "",
            replacement: c.ResourceChange?.Replacement ?? "N/A",
            scope: (c.ResourceChange?.Scope ?? []) as string[],
          }));
          record.changeCount = record.changes.length;
          record.summary = record.changes
            .map((c) =>
              `${c.action} ${c.logicalId} (${c.resourceType})` +
              (c.replacement === "True" ? " REPLACEMENT" : "") +
              (c.scope.length ? ` [${c.scope.join(",")}]` : "")
            )
            .join("; ");
        }

        ctx.logger.info("Change set {name}: {summary}", {
          name: changeSetName,
          summary: record.summary,
        });
        const handle = await ctx.writeResource(
          "changeSet",
          "changeSet",
          record,
        );
        return { dataHandles: [handle] };
      },
    },
    apply: {
      description:
        "Execute the change set recorded by the last plan and wait for the stack to settle",
      arguments: z.object({
        timeoutMinutes: z.number().default(45),
      }),
      execute: async (args: { timeoutMinutes: number }, ctx: Context) => {
        const ga = ctx.globalArgs;
        const plan = await ctx.readResource!("changeSet") as ChangeSet | null;
        if (!plan) throw new Error("No change set recorded — run plan first");
        if (plan.status === "applied") {
          throw new Error(
            `Change set ${plan.changeSetName} was already applied; plan again`,
          );
        }
        if (plan.status === "empty") {
          ctx.logger.info("Nothing to apply: the last plan had no changes");
          const handle = await ctx.writeResource(
            "changeSet",
            "changeSet",
            plan,
          );
          return { dataHandles: [handle] };
        }

        const cfn = client(ga);
        // Refuse a change set that went stale (stack changed since plan).
        const desc = await cfn.send(
          new DescribeChangeSetCommand({ ChangeSetName: plan.changeSetId }),
        );
        if (desc.ExecutionStatus !== "AVAILABLE") {
          throw new Error(
            `Change set ${plan.changeSetName} is ${desc.ExecutionStatus} (${
              desc.StatusReason ?? ""
            }); plan again`,
          );
        }

        await cfn.send(
          new ExecuteChangeSetCommand({ ChangeSetName: plan.changeSetId }),
        );
        ctx.logger.info("Executing {name}", { name: plan.changeSetName });

        const deadline = Date.now() + args.timeoutMinutes * 60_000;
        let status = "";
        while (true) {
          const stacks = await cfn.send(
            new DescribeStacksCommand({ StackName: ga.StackName }),
          );
          const stack = stacks.Stacks![0];
          status = stack.StackStatus!;
          if (!status.endsWith("_IN_PROGRESS")) {
            if (status !== "UPDATE_COMPLETE") {
              throw new Error(
                `Stack ${ga.StackName} ended ${status}: ${
                  stack.StackStatusReason ?? ""
                }`,
              );
            }
            break;
          }
          if (Date.now() > deadline) {
            throw new Error(
              `Stack ${ga.StackName} still ${status} after ${args.timeoutMinutes} minutes`,
            );
          }
          ctx.logger.info("{stack}: {status}", { stack: ga.StackName, status });
          await sleep(15_000);
        }

        const handle = await ctx.writeResource("changeSet", "changeSet", {
          ...plan,
          status: "applied",
          stackStatus: status,
          appliedAt: new Date().toISOString(),
        });
        return { dataHandles: [handle] };
      },
    },
  }],
};
